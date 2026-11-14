//! `backgroundActivity`, desktop-qt's BackgroundActivityController:
//! Settings → General, Background activity. The profile the selected
//! environments' MCs gate their background work by (`backgroundActivity`,
//! HalC2.BackgroundPolicy), and with Advanced chosen the Git fetch interval
//! and whether work pauses while the host is locked, kept as a custom
//! profile's overrides on the profile it started from. Environment-wide: a
//! project has none of its own.
//!
//! Publishes `backgroundActivity`: {open, profile (balanced | performance |
//! battery-saver | custom), mixed, advanced (profile is custom),
//! fetchSeconds, pauseWhenLocked, profiles: [{value, label}]}.
//!
//! Actions: `backgroundActivity.profile {value}` (custom keeps the current
//! profile as its base), `backgroundActivity.set {fetchSeconds?,
//! pauseWhenLocked?}` (a custom profile's overrides).

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{Controller, Init, Me};
use crate::controllers::settings::Map;
use crate::controllers::settings_scope::SettingsScope;
use crate::json::Json;
use crate::settings_page;

const KEY: &str = "backgroundActivity";
const FETCH: &str = "automaticGitFetchInterval";
const LOCKED: &str = "pauseWhenHostLocked";
const CUSTOM: &str = "custom";

/// A preset and the fetch interval HalC2.BackgroundPolicy gives it.
struct Profile {
    value: &'static str,
    label: &'static str,
    fetch_seconds: i64,
}

const PROFILES: [Profile; 3] = [
    Profile {
        value: "balanced",
        label: "Balanced",
        fetch_seconds: 30,
    },
    Profile {
        value: "performance",
        label: "Performance",
        fetch_seconds: 15,
    },
    Profile {
        value: "battery-saver",
        label: "Battery saver",
        fetch_seconds: 0,
    },
];

/// The preset a profile is, or (custom) was started from.
pub(crate) fn base_of(activity: &Map) -> &'static str {
    let profile = activity
        .get("profile")
        .and_then(Json::as_str)
        .unwrap_or_default();
    let base = if profile == CUSTOM {
        activity
            .get("baseProfile")
            .and_then(Json::as_str)
            .unwrap_or_default()
    } else {
        profile
    };
    match base {
        "performance" => "performance",
        "battery-saver" => "battery-saver",
        _ => "balanced",
    }
}

pub(crate) fn preset_fetch(profile: &str) -> i64 {
    PROFILES
        .iter()
        .find(|p| p.value == profile)
        .map_or(30, |p| p.fetch_seconds)
}

fn is_custom(activity: &Map) -> bool {
    activity.get("profile").and_then(Json::as_str) == Some(CUSTOM)
}

/// A custom profile's overrides; none for a preset.
fn overrides_of(activity: &Map) -> Map {
    if !is_custom(activity) {
        return Map::new();
    }
    activity
        .get("overrides")
        .and_then(Json::as_object)
        .cloned()
        .unwrap_or_default()
}

pub struct BackgroundActivity {
    bridge: Bridge,
    me: Me<BackgroundActivity>,
    active: bool,
    open: bool,
}

impl Controller for BackgroundActivity {
    fn new(init: Init<'_, Self>) -> Self {
        BackgroundActivity {
            bridge: init.bridge,
            me: init.me,
            active: false,
            open: false,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let me = self.me.clone();
        self.bridge.watch(engine, "route", move |engine, route| {
            let open = settings_page::general_open(route);
            me.run(engine, |c, engine| c.set_open(engine, open));
        });
        let me = self.me.clone();
        SettingsScope::of(engine).on_changed(move |engine| {
            me.run(engine, |c, engine| c.publish(engine));
        });
        let route = self.bridge.published(engine, "route").unwrap_or(Json::Null);
        self.set_open(engine, settings_page::general_open(&route));
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !self.active || !action.starts_with("backgroundActivity.") {
            return false;
        }
        match action {
            "backgroundActivity.profile" => {
                let value = settings_page::text(payload, "value").to_owned();
                if !PROFILES.iter().any(|p| p.value == value) && value != CUSTOM {
                    return true;
                }
                self.write(engine, move |activity| {
                    if value != CUSTOM {
                        return json!({"schemaVersion": 1, "profile": value, "overrides": {}});
                    }
                    // Advanced starts from the profile it was on, with nothing
                    // changed yet.
                    json!({
                        "schemaVersion": 1,
                        "profile": CUSTOM,
                        "baseProfile": base_of(activity),
                        "overrides": overrides_of(activity),
                    })
                });
            }
            "backgroundActivity.set" => {
                let input = payload.clone();
                self.write(engine, move |activity| {
                    let mut overrides = overrides_of(activity);
                    if let Some(seconds) = input.get("fetchSeconds") {
                        let seconds = settings_page::int(Some(seconds)).clamp(0, 86400);
                        overrides.insert(FETCH.into(), json!(seconds * 1000));
                    }
                    if let Some(locked) = input.get("pauseWhenLocked") {
                        overrides.insert(LOCKED.into(), json!(settings_page::flag(Some(locked))));
                    }
                    json!({
                        "schemaVersion": 1,
                        "profile": CUSTOM,
                        "baseProfile": base_of(activity),
                        "overrides": overrides,
                    })
                });
            }
            _ => {}
        }
        true
    }
}

impl BackgroundActivity {
    fn set_open(&mut self, engine: &Engine, open: bool) {
        self.open = open;
        self.publish(engine);
    }

    /// Replaces the activity setting with what `edit` makes of the one
    /// written now, on every environment of the scope.
    fn write(&self, engine: &Engine, edit: impl Fn(&Map) -> Json + 'static) {
        SettingsScope::of(engine).write(
            engine,
            move |mut settings, _| {
                let activity = settings
                    .get(KEY)
                    .and_then(Json::as_object)
                    .cloned()
                    .unwrap_or_default();
                settings.insert(KEY.into(), edit(&activity));
                settings
            },
            "",
        );
    }

    fn publish(&self, engine: &Engine) {
        if !self.active {
            return;
        }
        if !self.open {
            self.bridge.publish(engine, KEY, json!({"open": false}));
            return;
        }
        let reading = SettingsScope::of(engine).read(|settings, _| {
            Some(
                settings
                    .get(KEY)
                    .filter(|v| v.is_object())
                    .cloned()
                    .unwrap_or_else(|| json!({})),
            )
        });
        let activity = reading
            .value
            .as_ref()
            .and_then(Json::as_object)
            .cloned()
            .unwrap_or_default();
        let profile = activity
            .get("profile")
            .and_then(Json::as_str)
            .unwrap_or("balanced");
        let custom = profile == CUSTOM;
        let overrides = overrides_of(&activity);
        let mut profiles: Vec<Json> = PROFILES
            .iter()
            .map(|p| json!({"value": p.value, "label": p.label}))
            .collect();
        profiles.push(json!({"value": CUSTOM, "label": "Advanced"}));
        let fetch_seconds = match overrides.get(FETCH).and_then(Json::as_f64) {
            Some(ms) => (ms / 1000.0).round() as i64,
            None => preset_fetch(base_of(&activity)),
        };
        self.bridge.publish(
            engine,
            KEY,
            json!({
                "open": true,
                "profile": profile,
                "mixed": reading.mixed,
                "advanced": custom && !reading.mixed,
                "fetchSeconds": fetch_seconds,
                // Every preset pauses while the host is locked.
                "pauseWhenLocked": overrides.get(LOCKED).and_then(Json::as_bool).unwrap_or(true),
                "profiles": profiles,
            }),
        );
    }
}
