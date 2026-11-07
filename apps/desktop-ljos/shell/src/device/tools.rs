//! The Tools drawer of a device tab (`DeviceTab.tools`, desktop-qt's
//! DeviceTools): the shown device's own settings and one-shot actions,
//! through the MC's `device.detail` and `device.action` (never the hub's
//! shell channel; see docs/internals/devices.md), plus the read-only hub
//! feeds the proxy allowlists: the foreground app and the simulator's event
//! log over server-sent events, and the accessibility tree the overlay
//! draws.
//!
//! Every change is one `device.action`; the detail it returns replaces what
//! the controls show, so a refused change never reads as applied. While a
//! change runs (or the first detail is read) every control is disabled.
//!
//! Publishes `view` for the DevicePanel brick:
//!   {open, platform, loaded, pending, error,
//!    foreground (the app in front's id, or "—"), hasForeground, canRelaunch,
//!    settings: the detail's settings as read (absent = the device does not
//!    report it, and its control cannot be changed),
//!    latitude, longitude (as typed), eventLogOffered, eventLogOpen,
//!    events: [{time, summary}], axOverlay, axOffered (device access),
//!    axElements: [{label, x, y, width, height}] normalized to the screen}.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use ljos::prelude::{
    Atom, Cx, Engine, EngineError, ObjectId, QmlObject, QmlValue, Value, qml_impl,
};
use serde_json::json;

use super::percent;
use crate::json::Json;
use crate::mc::{Mc, McError, StreamEvent, StreamId};

const EVENT_LOG_LIMIT: usize = 100;
const AX_ELEMENT_LIMIT: usize = 500;
const AX_TIMEOUT_MS: i32 = 5000;
const FOREGROUND_RETRY_MS: i32 = 2000;
const FOREGROUND_RETRY_MAX_MS: i32 = 30000;
const AX_REFRESH_MS: i32 = 500;

// The drawer's labels for the settings' values (DeviceToolsPanel).
const TEXT_SIZES: [(&str, &str); 4] = [
    ("Small", "small"),
    ("Default", "default"),
    ("Large", "large"),
    ("Extra large", "extra-large"),
];
const COLOR_FILTERS: [(&str, &str); 5] = [
    ("None", "none"),
    ("Grayscale", "grayscale"),
    ("Red / green (protanopia)", "red-green"),
    ("Green / red (deuteranopia)", "green-red"),
    ("Blue / yellow (tritanopia)", "blue-yellow"),
];
const ORIENTATIONS: [(&str, &str); 4] = [
    ("Portrait", "portrait"),
    ("Landscape left", "landscape_left"),
    ("Upside down", "portrait_upside_down"),
    ("Landscape right", "landscape_right"),
];
// Permission labels, by either platform's spelling, to the contract's values.
const PERMISSIONS: [(&str, &str); 12] = [
    ("Camera", "camera"),
    ("Microphone", "microphone"),
    ("Photos", "photos"),
    ("Contacts", "contacts"),
    ("Calendar", "calendar"),
    ("Reminders", "reminders"),
    ("Location", "location"),
    ("Notifications", "notifications"),
    ("Motion", "motion"),
    ("Physical activity", "motion"),
    ("Media library", "media-library"),
    ("Face ID", "faceid"),
];
/// The location presets: city, latitude, longitude.
pub const PRESETS: [(&str, f64, f64); 5] = [
    ("San Francisco", 37.7749, -122.4194),
    ("New York", 40.7128, -74.006),
    ("London", 51.5074, -0.1278),
    ("Stockholm", 59.3293, 18.0686),
    ("Tokyo", 35.6762, 139.6503),
];
const TOGGLES: [(&str, &str); 6] = [
    ("Reduce Motion", "reduceMotion"),
    ("Increase Contrast", "increaseContrast"),
    ("Reduce Transparency", "reduceTransparency"),
    ("Show Borders", "showBorders"),
    ("VoiceOver", "voiceOver"),
    ("Network", "networkEnabled"),
];

fn lookup(table: &[(&str, &'static str)], label: &str) -> &'static str {
    table
        .iter()
        .find(|(l, _)| *l == label)
        .map_or("", |(_, v)| v)
}

/// The two server-sent-event feeds.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Feed {
    Foreground,
    EventLog,
}

/// What the core asks its runner for.
#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    /// `device.detail` (`action` false) or `device.action`, answered with
    /// [`Tools::on_reply`].
    Call {
        environment: String,
        method: &'static str,
        payload: Json,
        generation: u64,
        action: bool,
    },
    /// GET `path`?`query`, its body handed to [`Tools::on_feed_data`] and
    /// its end to [`Tools::on_feed_end`] under `token`.
    Follow {
        feed: Feed,
        path: String,
        query: String,
        token: u64,
    },
    Unfollow(Feed),
    /// GET the accessibility tree; its body goes to [`Tools::on_ax`], or
    /// [`Tools::on_ax_timeout`] after [`AX_TIMEOUT_MS`].
    FetchAx {
        path: String,
        query: String,
        token: u64,
    },
    DropAx,
    /// Follow the foreground again after this long; None stops waiting.
    Retry(Option<i32>),
    /// Refresh the accessibility tree every [`AX_REFRESH_MS`], or stop.
    AxTimer(bool),
}

/// The drawer's state, without the engine.
#[derive(Debug)]
pub struct Tools {
    environment: String,
    hub_base: String,
    host_id: String,
    device_id: String,
    platform: String,
    generation: u64,
    next_token: u64,

    open: bool,
    loaded: bool,
    pending: bool,
    error: String,
    settings: Json,
    /// The foreground app: the detail's, until the feed says another (or none).
    foreground: String,
    /// The last app seen in front: Relaunch after Terminate names it.
    last_foreground: String,
    foreground_live: bool,
    /// How long the next retry waits: it doubles while the feed keeps ending.
    foreground_wait: i32,
    latitude: String,
    longitude: String,

    feeds: HashMap<Feed, (u64, Vec<u8>)>,
    event_log_open: bool,
    events: Vec<Json>,

    ax_overlay: bool,
    /// The accessibility request out, if one is.
    ax_out: Option<u64>,
    ax_elements: Vec<Json>,

    view: Json,
    view_changed: bool,
    effects: Vec<Effect>,
}

impl Default for Tools {
    fn default() -> Self {
        let mut tools = Tools {
            environment: String::new(),
            hub_base: String::new(),
            host_id: String::new(),
            device_id: String::new(),
            platform: String::new(),
            generation: 0,
            next_token: 0,
            open: false,
            loaded: false,
            pending: false,
            error: String::new(),
            settings: json!({}),
            foreground: String::new(),
            last_foreground: String::new(),
            foreground_live: false,
            foreground_wait: FOREGROUND_RETRY_MS,
            latitude: String::new(),
            longitude: String::new(),
            feeds: HashMap::new(),
            event_log_open: false,
            events: Vec::new(),
            ax_overlay: false,
            ax_out: None,
            ax_elements: Vec::new(),
            view: Json::Null,
            view_changed: false,
            effects: Vec::new(),
        };
        tools.publish();
        tools
    }
}

impl Tools {
    pub fn view(&self) -> &Json {
        &self.view
    }

    pub fn take_effects(&mut self) -> Vec<Effect> {
        std::mem::take(&mut self.effects)
    }

    pub fn take_view_changed(&mut self) -> bool {
        std::mem::replace(&mut self.view_changed, false)
    }

    fn ios(&self) -> bool {
        self.platform == "ios"
    }

    fn token(&mut self) -> u64 {
        self.next_token += 1;
        self.next_token
    }

    /// The device whose tab shows (all empty: none). A different device
    /// starts fresh.
    pub fn set_target(
        &mut self,
        environment: &str,
        hub_base: &str,
        host_id: &str,
        device_id: &str,
        platform: &str,
    ) {
        if environment == self.environment
            && hub_base == self.hub_base
            && host_id == self.host_id
            && device_id == self.device_id
            && platform == self.platform
        {
            return;
        }
        self.generation += 1;
        self.unfollow(Feed::Foreground);
        self.unfollow(Feed::EventLog);
        self.environment = environment.into();
        self.hub_base = hub_base.into();
        self.host_id = host_id.into();
        self.device_id = device_id.into();
        self.platform = platform.into();
        self.loaded = false;
        self.pending = false;
        self.error.clear();
        self.settings = json!({});
        self.foreground.clear();
        self.foreground_live = false;
        self.last_foreground.clear();
        self.effects.push(Effect::Retry(None));
        self.foreground_wait = FOREGROUND_RETRY_MS;
        self.latitude.clear();
        self.longitude.clear();
        self.events.clear();
        self.event_log_open = false;
        self.ax_overlay = false;
        self.effects.push(Effect::AxTimer(false));
        self.ax_elements.clear();
        self.drop_ax();
        if self.open && !self.device_id.is_empty() {
            self.read();
            self.follow_foreground();
        }
        self.publish();
    }

    pub fn set_open(&mut self, open: bool) {
        if open == self.open {
            return;
        }
        self.open = open;
        if open {
            // The settings are read again on every open: they may have
            // changed on the device while the drawer was away.
            if !self.device_id.is_empty() {
                self.loaded = false;
                self.read();
            }
            self.follow_foreground();
        } else {
            self.unfollow(Feed::Foreground);
            self.effects.push(Effect::Retry(None));
            self.foreground_wait = FOREGROUND_RETRY_MS;
            self.foreground_live = false;
            self.unfollow(Feed::EventLog);
            self.events.clear();
            self.event_log_open = false;
            self.set_ax_overlay(false);
        }
        self.publish();
    }

    fn read(&mut self) {
        // A change out keeps its own refusal; this read reports only its own.
        if !self.pending {
            self.error.clear();
        }
        self.effects.push(Effect::Call {
            environment: self.environment.clone(),
            method: "device.detail",
            payload: json!({"hostId": self.host_id, "deviceId": self.device_id}),
            generation: self.generation,
            action: false,
        });
    }

    /// The MC answered a call made for `generation`.
    pub fn on_reply(&mut self, generation: u64, action: bool, result: Result<Json, String>) {
        if generation != self.generation {
            return;
        }
        match result {
            Ok(detail) => self.take(&detail, action),
            Err(error) => {
                if action {
                    self.pending = false;
                }
                self.error = error;
                self.publish();
            }
        }
    }

    /// `action` ends the change that was out; a plain read landing while
    /// one is out must not.
    fn take(&mut self, detail: &Json, action: bool) {
        self.settings = match &detail["settings"] {
            Json::Object(settings) => Json::Object(settings.clone()),
            _ => json!({}),
        };
        if !self.foreground_live {
            self.foreground = detail["foregroundApp"]["id"]
                .as_str()
                .unwrap_or_default()
                .to_owned();
        }
        if !self.foreground.is_empty() {
            self.last_foreground = self.foreground.clone();
        }
        self.loaded = true;
        if action {
            self.pending = false;
        }
        self.publish();
    }

    fn act(&mut self, mut action: Json) {
        if self.pending || self.device_id.is_empty() {
            return;
        }
        self.pending = true;
        self.error.clear();
        self.publish();
        action["hostId"] = json!(self.host_id);
        action["deviceId"] = json!(self.device_id);
        self.effects.push(Effect::Call {
            environment: self.environment.clone(),
            method: "device.action",
            payload: action,
            generation: self.generation,
            action: true,
        });
    }

    /// A choice control (Appearance, Text size, Liquid Glass, Color filter,
    /// Orientation) picked `choice`, its label as the drawer shows it.
    pub fn choose(&mut self, control: &str, choice: &str) {
        let (kind, value) = match control {
            "Appearance" => (
                "setAppearance",
                if choice == "Dark" { "dark" } else { "light" },
            ),
            "Text size" => ("setTextSize", lookup(&TEXT_SIZES, choice)),
            "Liquid Glass" => (
                "setLiquidGlass",
                if choice == "Tinted" {
                    "tinted"
                } else {
                    "clear"
                },
            ),
            "Color filter" => ("setColorFilter", lookup(&COLOR_FILTERS, choice)),
            "Orientation" => ("setOrientation", lookup(&ORIENTATIONS, choice)),
            _ => return,
        };
        self.act(json!({"type": kind, "value": value}));
    }

    pub fn set_switch(&mut self, setting: &str, on: bool) {
        let key = TOGGLES
            .iter()
            .find(|(l, _)| *l == setting)
            .map_or(setting, |(_, k)| k);
        self.act(json!({"type": "setToggle", "setting": key, "value": on}));
    }

    /// The Open (a URL) and Launch (an app id) rows.
    pub fn submit(&mut self, field: &str, value: &str) {
        let value = value.trim();
        if value.is_empty() {
            return;
        }
        match field {
            "url" => self.act(json!({"type": "openUrl", "url": value})),
            "launch" => self.act(json!({"type": "launchApp", "appId": value})),
            _ => {}
        }
    }

    pub fn terminate(&mut self) {
        if !self.foreground.is_empty() {
            let app = self.foreground.clone();
            self.act(json!({"type": "terminateApp", "appId": app}));
        }
    }

    pub fn relaunch(&mut self) {
        let app = if self.foreground.is_empty() {
            self.last_foreground.clone()
        } else {
            self.foreground.clone()
        };
        if !app.is_empty() {
            self.act(json!({"type": "launchApp", "appId": app}));
        }
    }

    pub fn set_location_text(&mut self, latitude: &str, longitude: &str) {
        if latitude == self.latitude && longitude == self.longitude {
            return;
        }
        self.latitude = latitude.into();
        self.longitude = longitude.into();
        self.publish();
    }

    pub fn apply_location(&mut self) {
        let (Ok(latitude), Ok(longitude)) = (
            self.latitude.trim().parse::<f64>(),
            self.longitude.trim().parse::<f64>(),
        ) else {
            return;
        };
        if !latitude.is_finite()
            || !longitude.is_finite()
            || latitude.abs() > 90.0
            || longitude.abs() > 180.0
        {
            return;
        }
        self.act(json!({"type": "setLocation", "latitude": latitude, "longitude": longitude}));
    }

    pub fn apply_preset(&mut self, city: &str) {
        let Some((_, latitude, longitude)) = PRESETS.iter().find(|(c, _, _)| *c == city) else {
            return;
        };
        self.latitude = latitude.to_string();
        self.longitude = longitude.to_string();
        self.publish();
        self.act(json!({"type": "setLocation", "latitude": latitude, "longitude": longitude}));
    }

    pub fn clear_location(&mut self) {
        self.latitude.clear();
        self.longitude.clear();
        self.publish();
        self.act(json!({"type": "clearLocation"}));
    }

    pub fn decide(&mut self, app_id: &str, permission: &str, decision: &str) {
        let app = if app_id.trim().is_empty() {
            self.foreground.clone()
        } else {
            app_id.trim().to_owned()
        };
        if app.is_empty() {
            return;
        }
        self.act(json!({
            "type": "setPermission",
            "appId": app,
            "permission": lookup(&PERMISSIONS, permission),
            "decision": decision.to_lowercase(),
        }));
    }

    pub fn send_push(&mut self, text: &str) {
        if self.foreground.is_empty() || text.trim().is_empty() {
            return;
        }
        let app = self.foreground.clone();
        self.act(json!({"type": "sendPush", "appId": app, "payload": text.trim()}));
    }

    fn vendor_path(&self, path: &str) -> String {
        let vendor = if self.ios() {
            "/vendor/serve-sim"
        } else {
            "/vendor/serve-emu"
        };
        format!("{}{vendor}{path}", self.hub_base)
    }

    fn follow(&mut self, feed: Feed, path: &str) {
        self.unfollow(feed);
        let token = self.token();
        self.feeds.insert(feed, (token, Vec::new()));
        self.effects.push(Effect::Follow {
            feed,
            path: self.vendor_path(path),
            query: format!("device={}", percent(&self.device_id)),
            token,
        });
    }

    fn unfollow(&mut self, feed: Feed) {
        if self.feeds.remove(&feed).is_some() {
            self.effects.push(Effect::Unfollow(feed));
        }
    }

    fn follow_foreground(&mut self) {
        // iOS only: serve-sim pushes the frontmost app as it changes.
        if !self.open || !self.ios() || self.hub_base.is_empty() || self.device_id.is_empty() {
            return;
        }
        self.follow(Feed::Foreground, "/appstate");
    }

    /// The foreground retry's timer fired.
    pub fn retry_foreground(&mut self) {
        self.follow_foreground();
    }

    /// More of a feed's body.
    pub fn on_feed_data(&mut self, feed: Feed, token: u64, bytes: &[u8]) {
        let lines = {
            let Some((current, buffer)) = self.feeds.get_mut(&feed) else {
                return;
            };
            if *current != token {
                return;
            }
            buffer.extend_from_slice(bytes);
            let mut lines = Vec::new();
            while let Some(at) = buffer.iter().position(|b| *b == b'\n') {
                let line: Vec<u8> = buffer.drain(..=at).collect();
                lines.push(String::from_utf8_lossy(&line).trim().to_owned());
            }
            lines
        };
        for line in lines {
            let Some(data) = line.strip_prefix("data:") else {
                continue;
            };
            let Ok(Json::Object(event)) = serde_json::from_str::<Json>(data.trim()) else {
                continue;
            };
            if event.is_empty() {
                continue;
            }
            match feed {
                Feed::Foreground => self.on_foreground(&event),
                Feed::EventLog => self.on_event_log(&event),
            }
        }
    }

    fn on_foreground(&mut self, event: &serde_json::Map<String, Json>) {
        let Some(bundle) = event.get("bundleId") else {
            return;
        };
        self.foreground = bundle.as_str().unwrap_or_default().to_owned();
        self.foreground_live = true;
        self.foreground_wait = FOREGROUND_RETRY_MS;
        if !self.foreground.is_empty() {
            self.last_foreground = self.foreground.clone();
        }
        self.publish();
    }

    fn on_event_log(&mut self, event: &serde_json::Map<String, Json>) {
        let add = |events: &mut Vec<Json>, entry: &Json| {
            if !entry["id"].is_number() {
                return;
            }
            let stamp = entry["timestamp"].as_str().unwrap_or_default();
            let time = if stamp.chars().count() >= 19 {
                stamp.chars().skip(11).take(8).collect()
            } else {
                stamp.to_owned()
            };
            let summary = match entry.get("summary") {
                Some(summary) => summary.as_str().unwrap_or_default(),
                None => entry["msg"].as_str().unwrap_or_default(),
            };
            events.push(json!({"time": time, "summary": summary}));
        };
        if let Some(Json::Array(all)) = event.get("events") {
            self.events.clear();
            for entry in all {
                add(&mut self.events, entry);
            }
        } else if let Some(entry) = event.get("event") {
            match entry {
                Json::Array(all) => {
                    for entry in all {
                        add(&mut self.events, entry);
                    }
                }
                entry => add(&mut self.events, entry),
            }
        } else {
            return;
        }
        if self.events.len() > EVENT_LOG_LIMIT {
            let extra = self.events.len() - EVENT_LOG_LIMIT;
            self.events.drain(..extra);
        }
        self.publish();
    }

    /// A feed ended (a hub restart, say).
    pub fn on_feed_end(&mut self, feed: Feed, token: u64) {
        if self.feeds.get(&feed).map(|(t, _)| *t) != Some(token) {
            return;
        }
        self.feeds.remove(&feed);
        if feed != Feed::Foreground || !self.open {
            return;
        }
        // What the feed last said no longer holds: read the app in front
        // once and keep trying to follow it, waiting longer after each try
        // that ends before saying anything.
        if self.foreground_live {
            self.foreground_live = false;
            self.read();
        }
        self.effects.push(Effect::Retry(Some(self.foreground_wait)));
        self.foreground_wait = (self.foreground_wait * 2).min(FOREGROUND_RETRY_MAX_MS);
        self.publish();
    }

    pub fn set_event_log_open(&mut self, open: bool) {
        if open == self.event_log_open {
            return;
        }
        self.event_log_open = open;
        self.events.clear();
        if open {
            if self.ios() && !self.hub_base.is_empty() && !self.device_id.is_empty() {
                self.follow(Feed::EventLog, "/api/event-log/events");
            }
        } else {
            self.unfollow(Feed::EventLog);
        }
        self.publish();
    }

    pub fn set_ax_overlay(&mut self, on: bool) {
        if on == self.ax_overlay {
            return;
        }
        self.ax_overlay = on;
        if on {
            self.fetch_ax();
            self.effects.push(Effect::AxTimer(true));
        } else {
            self.effects.push(Effect::AxTimer(false));
            self.ax_elements.clear();
            self.drop_ax();
        }
        self.publish();
    }

    fn drop_ax(&mut self) {
        if self.ax_out.take().is_some() {
            self.effects.push(Effect::DropAx);
        }
    }

    /// One at a time: a stalled hub must not pile requests up.
    pub fn fetch_ax(&mut self) {
        if !self.ax_overlay
            || self.ax_out.is_some()
            || self.hub_base.is_empty()
            || self.device_id.is_empty()
        {
            return;
        }
        let token = self.token();
        self.ax_out = Some(token);
        let device = percent(&self.device_id);
        let (path, query) = if self.ios() {
            (
                self.vendor_path(&format!("/helper/{device}/ax")),
                String::new(),
            )
        } else {
            (
                self.vendor_path("/api/accessibility"),
                format!("device={device}"),
            )
        };
        self.effects.push(Effect::FetchAx { path, query, token });
    }

    /// The accessibility request `token` took too long.
    pub fn on_ax_timeout(&mut self, token: u64) {
        if self.ax_out == Some(token) {
            self.drop_ax();
        }
    }

    /// The accessibility request `token` ended with `body`.
    pub fn on_ax(&mut self, token: u64, body: &[u8]) {
        if self.ax_out != Some(token) {
            return;
        }
        self.ax_out = None;
        self.effects.push(Effect::DropAx);
        if !self.ax_overlay {
            return;
        }
        let Ok(document) = serde_json::from_slice::<Json>(body) else {
            return;
        };
        let elements = if self.ios() {
            let Json::Array(roots) = &document else {
                return;
            };
            let frame = roots.first().map_or(Json::Null, |r| r["frame"].clone());
            let width = number_or(&frame["width"], 1.0).max(1.0);
            let height = number_or(&frame["height"], 1.0).max(1.0);
            let mut out = Vec::new();
            for root in roots {
                flatten_ax(root, width, height, &mut out);
            }
            out
        } else {
            let Some(nodes) = document["nodes"].as_array().filter(|n| !n.is_empty()) else {
                return;
            };
            android_ax(nodes)
        };
        if elements == self.ax_elements {
            return;
        }
        self.ax_elements = elements;
        self.publish();
    }

    fn publish(&mut self) {
        let access = !self.hub_base.is_empty() && !self.device_id.is_empty();
        let view = json!({
            "open": self.open,
            "platform": self.platform,
            "loaded": self.loaded,
            "pending": self.pending,
            "error": self.error,
            "foreground": if self.foreground.is_empty() { "—" } else { &self.foreground },
            "hasForeground": !self.foreground.is_empty(),
            "canRelaunch": !self.last_foreground.is_empty(),
            "settings": self.settings,
            "latitude": self.latitude,
            "longitude": self.longitude,
            "eventLogOffered": access && self.ios(),
            "eventLogOpen": self.event_log_open,
            "events": self.events,
            "axOverlay": self.ax_overlay,
            "axOffered": access,
            "axElements": self.ax_elements,
        });
        if view != self.view {
            self.view = view;
            self.view_changed = true;
        }
    }
}

fn number_or(value: &Json, fallback: f64) -> f64 {
    value.as_f64().unwrap_or(fallback)
}

/// serve-sim's nested accessibility tree, flattened: nodes covering the
/// whole screen are skipped, frames normalized to the root's.
fn flatten_ax(node: &Json, screen_width: f64, screen_height: f64, out: &mut Vec<Json>) {
    if out.len() >= AX_ELEMENT_LIMIT || !node.is_object() {
        return;
    }
    let frame = &node["frame"];
    let width = number_or(&frame["width"], 0.0);
    let height = number_or(&frame["height"], 0.0);
    let covers = (width - screen_width).abs() < 0.5 && (height - screen_height).abs() < 0.5;
    if !covers && width > 0.0 && height > 0.0 {
        out.push(json!({
            "label": node["AXLabel"].as_str().unwrap_or_default(),
            "x": number_or(&frame["x"], 0.0) / screen_width,
            "y": number_or(&frame["y"], 0.0) / screen_height,
            "width": width / screen_width,
            "height": height / screen_height,
        }));
    }
    if let Some(children) = node["children"].as_array() {
        for child in children {
            flatten_ax(child, screen_width, screen_height, out);
        }
    }
}

/// serve-emu's flat node list, the first the screen: what covers the screen
/// and unlabelled nodes nobody can tap are skipped.
fn android_ax(nodes: &[Json]) -> Vec<Json> {
    let root = &nodes[0]["bounds"];
    let width = number_or(&root["right"], 1.0).max(1.0);
    let height = number_or(&root["bottom"], 1.0).max(1.0);
    let mut out = Vec::new();
    for node in &nodes[1..] {
        if out.len() >= AX_ELEMENT_LIMIT {
            break;
        }
        let bounds = &node["bounds"];
        let left = number_or(&bounds["left"], 0.0);
        let top = number_or(&bounds["top"], 0.0);
        let w = (number_or(&bounds["right"], left) - left) / width;
        let h = (number_or(&bounds["bottom"], top) - top) / height;
        let mut label = node["text"].as_str().unwrap_or_default();
        if label.is_empty() {
            label = node["contentDescription"].as_str().unwrap_or_default();
        }
        let clickable = node["clickable"].as_bool().unwrap_or(false);
        if (w >= 0.95 && h >= 0.9) || (label.is_empty() && !clickable) {
            continue;
        }
        out.push(json!({
            "label": label,
            "x": left / width,
            "y": top / height,
            "width": w,
            "height": h,
        }));
    }
    out
}

/// What the object keeps beside its core: the streams and timers it runs.
struct Inner {
    core: RefCell<Tools>,
    mc: Rc<dyn Mc>,
    feeds: RefCell<HashMap<Feed, StreamId>>,
    ax: RefCell<Option<(StreamId, Vec<u8>)>>,
    ax_timeout: RefCell<Option<ObjectId>>,
    ax_timer: RefCell<Option<ObjectId>>,
    retry: RefCell<Option<ObjectId>>,
}

impl Drop for Inner {
    fn drop(&mut self) {
        for (_, id) in self.feeds.get_mut().drain() {
            self.mc.close_stream(id);
        }
        if let Some((id, _)) = self.ax.get_mut().take() {
            self.mc.close_stream(id);
        }
    }
}

impl std::fmt::Debug for Inner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DeviceTools")
            .field("core", &self.core)
            .finish_non_exhaustive()
    }
}

/// A device tab's Tools drawer: `DeviceTab.tools`.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "DeviceTools", uncreatable)]
pub struct DeviceTools {
    #[qml(readonly, notify)]
    view: Value,
    #[qml(skip)]
    inner: Rc<Inner>,
}

fn inner_of(engine: &Engine, obj: ObjectId) -> Option<Rc<Inner>> {
    engine.with::<DeviceTools, _>(obj, |t| t.inner.clone()).ok()
}

fn warn(engine: &Engine, result: Result<(), EngineError>) {
    if let Err(e) = result {
        engine.log(
            ljos::prelude::LogLevel::Warning,
            "DeviceTools",
            e.to_string(),
        );
    }
}

impl DeviceTools {
    /// A drawer owned by `owner`, asking `mc`.
    pub fn create(
        engine: &Engine,
        owner: Option<ObjectId>,
        mc: Rc<dyn Mc>,
    ) -> Result<ObjectId, EngineError> {
        let core = Tools::default();
        let view = core.view().to_value();
        let inner = Rc::new(Inner {
            core: RefCell::new(core),
            mc,
            feeds: RefCell::default(),
            ax: RefCell::default(),
            ax_timeout: RefCell::default(),
            ax_timer: RefCell::default(),
            retry: RefCell::default(),
        });
        engine.create_native(DeviceTools { view, inner }, owner)
    }

    /// The device whose tab shows (all empty: none).
    pub fn set_target(
        engine: &Engine,
        obj: ObjectId,
        environment: &str,
        hub_base: &str,
        host_id: &str,
        device_id: &str,
        platform: &str,
    ) {
        Self::update(engine, obj, |t| {
            t.set_target(environment, hub_base, host_id, device_id, platform);
        });
    }

    /// Runs `f` on the drawer of `obj`, then publishes `view` and runs what
    /// it asked for. None when `obj` is not live.
    pub fn update<R>(engine: &Engine, obj: ObjectId, f: impl FnOnce(&mut Tools) -> R) -> Option<R> {
        let inner = inner_of(engine, obj)?;
        let (result, changed, view, effects) = {
            let mut core = inner.core.borrow_mut();
            let result = f(&mut core);
            let changed = core.take_view_changed();
            (result, changed, core.view().clone(), core.take_effects())
        };
        if changed {
            warn(
                engine,
                engine.set_internal(obj, DeviceTools::VIEW, view.to_value()),
            );
        }
        for effect in effects {
            run(engine, obj, &inner, effect);
        }
        Some(result)
    }

    /// Reads the drawer of `obj`.
    pub fn read<R>(engine: &Engine, obj: ObjectId, f: impl FnOnce(&Tools) -> R) -> Option<R> {
        let inner = inner_of(engine, obj)?;
        let core = inner.core.borrow();
        Some(f(&core))
    }
}

fn stop(engine: &Engine, slot: &RefCell<Option<ObjectId>>) {
    let old = slot.borrow_mut().take();
    if let Some(old) = old {
        engine.destroy(old);
    }
}

fn run(engine: &Engine, obj: ObjectId, inner: &Inner, effect: Effect) {
    match effect {
        Effect::Call {
            environment,
            method,
            payload,
            generation,
            action,
        } => inner.mc.call(
            &environment,
            method,
            payload,
            Box::new(move |engine, result: Result<Json, McError>| {
                let result = result.map_err(|e| e.message);
                DeviceTools::update(engine, obj, |t| t.on_reply(generation, action, result));
            }),
        ),
        Effect::Follow {
            feed,
            path,
            query,
            token,
        } => {
            let opened = inner.mc.open_stream(
                &path,
                &query,
                false,
                Box::new(move |engine, event| match event {
                    StreamEvent::Data(bytes) => {
                        DeviceTools::update(engine, obj, |t| t.on_feed_data(feed, token, &bytes));
                    }
                    StreamEvent::Ended(_) => {
                        DeviceTools::update(engine, obj, |t| t.on_feed_end(feed, token));
                    }
                    _ => {}
                }),
            );
            let old = match opened {
                Some(stream) => inner.feeds.borrow_mut().insert(feed, stream),
                None => inner.feeds.borrow_mut().remove(&feed),
            };
            if let Some(old) = old {
                inner.mc.close_stream(old);
            }
        }
        Effect::Unfollow(feed) => {
            let old = inner.feeds.borrow_mut().remove(&feed);
            if let Some(old) = old {
                inner.mc.close_stream(old);
            }
        }
        Effect::FetchAx { path, query, token } => {
            let opened = inner.mc.open_stream(
                &path,
                &query,
                false,
                Box::new(move |engine, event| {
                    let Some(inner) = inner_of(engine, obj) else {
                        return;
                    };
                    match event {
                        StreamEvent::Data(bytes) => {
                            if let Some((_, body)) = &mut *inner.ax.borrow_mut() {
                                body.extend_from_slice(&bytes);
                            }
                        }
                        StreamEvent::Ended(_) => {
                            let body = inner
                                .ax
                                .borrow_mut()
                                .take()
                                .map(|(_, body)| body)
                                .unwrap_or_default();
                            DeviceTools::update(engine, obj, |t| t.on_ax(token, &body));
                        }
                        _ => {}
                    }
                }),
            );
            let Some(stream) = opened else {
                DeviceTools::update(engine, obj, |t| t.on_ax(token, &[]));
                return;
            };
            let old = inner.ax.borrow_mut().replace((stream, Vec::new()));
            if let Some((old, _)) = old {
                inner.mc.close_stream(old);
            }
            stop(engine, &inner.ax_timeout);
            *inner.ax_timeout.borrow_mut() =
                timer(engine, obj, AX_TIMEOUT_MS, false, move |engine| {
                    DeviceTools::update(engine, obj, |t| t.on_ax_timeout(token));
                });
        }
        Effect::DropAx => {
            let old = inner.ax.borrow_mut().take();
            if let Some((old, _)) = old {
                inner.mc.close_stream(old);
            }
            stop(engine, &inner.ax_timeout);
        }
        Effect::Retry(wait) => {
            stop(engine, &inner.retry);
            if let Some(ms) = wait {
                *inner.retry.borrow_mut() = timer(engine, obj, ms, false, move |engine| {
                    DeviceTools::update(engine, obj, Tools::retry_foreground);
                });
            }
        }
        Effect::AxTimer(on) => {
            stop(engine, &inner.ax_timer);
            if on {
                *inner.ax_timer.borrow_mut() =
                    timer(engine, obj, AX_REFRESH_MS, true, move |engine| {
                        DeviceTools::update(engine, obj, Tools::fetch_ax);
                    });
            }
        }
    }
}

/// A timer owned by `obj` that runs `f` after `ms`, again and again with
/// `repeat`.
fn timer(
    engine: &Engine,
    obj: ObjectId,
    ms: i32,
    repeat: bool,
    f: impl Fn(&Engine) + 'static,
) -> Option<ObjectId> {
    let native = ljos::prelude::Timer {
        interval: ms,
        repeat,
        running: true,
        ..ljos::prelude::Timer::default()
    };
    let made = engine.create_native(native, Some(obj)).ok()?;
    engine
        .connect_by_name(made, "triggered", move |engine, _| f(engine))
        .ok()?;
    Some(made)
}

#[qml_impl]
impl DeviceTools {
    #[qml(invokable)]
    fn set_open(cx: &Cx, open: bool) {
        DeviceTools::update(cx.engine, cx.this, |t| t.set_open(open));
    }

    #[qml(invokable)]
    fn choose(cx: &Cx, control: Atom, choice: Atom) {
        DeviceTools::update(cx.engine, cx.this, |t| t.choose(&control, &choice));
    }

    #[qml(invokable)]
    fn set_switch(cx: &Cx, setting: Atom, on: bool) {
        DeviceTools::update(cx.engine, cx.this, |t| t.set_switch(&setting, on));
    }

    #[qml(invokable)]
    fn submit(cx: &Cx, field: Atom, value: Atom) {
        DeviceTools::update(cx.engine, cx.this, |t| t.submit(&field, &value));
    }

    #[qml(invokable)]
    fn terminate(cx: &Cx) {
        DeviceTools::update(cx.engine, cx.this, Tools::terminate);
    }

    #[qml(invokable)]
    fn relaunch(cx: &Cx) {
        DeviceTools::update(cx.engine, cx.this, Tools::relaunch);
    }

    #[qml(invokable)]
    fn set_location_text(cx: &Cx, latitude: Atom, longitude: Atom) {
        DeviceTools::update(cx.engine, cx.this, |t| {
            t.set_location_text(&latitude, &longitude);
        });
    }

    #[qml(invokable)]
    fn apply_location(cx: &Cx) {
        DeviceTools::update(cx.engine, cx.this, Tools::apply_location);
    }

    #[qml(invokable)]
    fn apply_preset(cx: &Cx, city: Atom) {
        DeviceTools::update(cx.engine, cx.this, |t| t.apply_preset(&city));
    }

    #[qml(invokable)]
    fn clear_location(cx: &Cx) {
        DeviceTools::update(cx.engine, cx.this, Tools::clear_location);
    }

    #[qml(invokable)]
    fn decide(cx: &Cx, app_id: Atom, permission: Atom, decision: Atom) {
        DeviceTools::update(cx.engine, cx.this, |t| {
            t.decide(&app_id, &permission, &decision);
        });
    }

    #[qml(invokable)]
    fn send_push(cx: &Cx, text: Atom) {
        DeviceTools::update(cx.engine, cx.this, |t| t.send_push(&text));
    }

    #[qml(invokable)]
    fn set_event_log_open(cx: &Cx, open: bool) {
        DeviceTools::update(cx.engine, cx.this, |t| t.set_event_log_open(open));
    }

    #[qml(invokable)]
    fn set_ax_overlay(cx: &Cx, on: bool) {
        DeviceTools::update(cx.engine, cx.this, |t| t.set_ax_overlay(on));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn opened(platform: &str) -> Tools {
        let mut tools = Tools::default();
        tools.set_target("env", "/hub", "local", "D1", platform);
        tools.set_open(true);
        tools.take_effects();
        tools
    }

    #[test]
    fn a_refused_change_keeps_what_the_device_reported() {
        let mut tools = opened("ios");
        let generation = tools.generation;
        tools.on_reply(
            generation,
            false,
            Ok(json!({"settings": {"appearance": "light"}})),
        );
        tools.choose("Appearance", "Dark");
        assert_eq!(tools.view()["pending"], true);
        tools.choose("Appearance", "Light");
        assert_eq!(tools.take_effects().len(), 1, "one change at a time");
        tools.on_reply(generation, true, Err("Not allowed".into()));
        assert_eq!(tools.view()["error"], "Not allowed");
        assert_eq!(tools.view()["pending"], false);
        assert_eq!(tools.view()["settings"]["appearance"], "light");
    }

    #[test]
    fn a_feed_that_ends_is_followed_again_ever_later() {
        let mut tools = opened("ios");
        let Some((token, _)) = tools.feeds.get(&Feed::Foreground).cloned() else {
            panic!("no foreground feed");
        };
        tools.on_feed_data(Feed::Foreground, token, b"data: {\"bundleId\":\"com.a\"}\n");
        assert_eq!(tools.view()["foreground"], "com.a");
        tools.on_feed_end(Feed::Foreground, token);
        let effects = tools.take_effects();
        assert!(effects.contains(&Effect::Retry(Some(FOREGROUND_RETRY_MS))));
        assert!(
            effects
                .iter()
                .any(|e| matches!(e, Effect::Call { action: false, .. }))
        );
        tools.retry_foreground();
        let Some((token, _)) = tools.feeds.get(&Feed::Foreground).cloned() else {
            panic!("not followed again");
        };
        tools.on_feed_end(Feed::Foreground, token);
        assert!(
            tools
                .take_effects()
                .contains(&Effect::Retry(Some(FOREGROUND_RETRY_MS * 2)))
        );
    }

    #[test]
    fn the_event_log_keeps_the_latest_hundred() {
        let mut tools = opened("ios");
        tools.set_event_log_open(true);
        let Some((token, _)) = tools.feeds.get(&Feed::EventLog).cloned() else {
            panic!("no event feed");
        };
        let events: Vec<Json> = (1..=105)
            .map(|id| json!({"id": id, "timestamp": "2026-09-23T10:00:01Z", "summary": format!("Event {id}")}))
            .collect();
        let line = format!("data: {}\n\n", json!({"events": events}));
        tools.on_feed_data(Feed::EventLog, token, line.as_bytes());
        let events = tools.view()["events"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        assert_eq!(events.len(), 100);
        assert_eq!(events[0], json!({"time": "10:00:01", "summary": "Event 6"}));
    }

    #[test]
    fn only_one_accessibility_request_is_out() {
        let mut tools = opened("android");
        tools.set_ax_overlay(true);
        tools.fetch_ax();
        let fetches = tools
            .take_effects()
            .into_iter()
            .filter(|e| matches!(e, Effect::FetchAx { .. }))
            .count();
        assert_eq!(fetches, 1);
        let mut nodes = vec![json!({"bounds": {"right": 1000, "bottom": 2000}})];
        for n in 0..600 {
            nodes.push(json!({"text": format!("Item {n}"), "bounds": {"left": 0, "top": n, "right": 100, "bottom": n + 1}}));
        }
        let body = serde_json::to_vec(&json!({ "nodes": nodes })).unwrap_or_default();
        let token = tools.ax_out.unwrap_or_default();
        tools.on_ax(token, &body);
        assert_eq!(
            tools.view()["axElements"].as_array().map(Vec::len),
            Some(500)
        );
    }
}
