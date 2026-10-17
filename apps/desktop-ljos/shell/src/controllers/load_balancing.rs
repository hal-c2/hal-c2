//! `loadBalancing`, desktop-qt's LoadBalancingController: Settings →
//! Connections' "Load balancing" group. Whether new threads start on the
//! machine with the most room, and how often each machine of the cluster
//! gets them. Both are in the settings document of the MC this shell is
//! connected to (`loadBalancingEnabled`, and `loadBalancingWeights` by
//! environment id), because that MC is the one that chooses
//! (HalC2.LoadBalancing, which the composer asks with
//! `hal-c2.placeThread`).
//!
//! Publishes `loadBalancing`: null while the cluster has one machine (there
//! is nothing to balance against), else {ready (the settings are read),
//! enabled, summary (what the folded group says: "Off", or the machines not
//! at Normal), preferences [{weight, label}], machines [{environmentId,
//! label, weight}]}, this machine first and the others by name. A machine's
//! `weight` is the preference it shows as: one of `preferences`, whatever
//! was saved.
//!
//! Actions: `loadBalancing.enable {enabled}` (the preferences stay as they
//! are) and `loadBalancing.prefer {environmentId, weight}` (one of
//! `preferences`).

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::settings::{Map, Settings};
use crate::controllers::settings_scope::SettingsScope;
use crate::controllers::toasts::{DEFAULT_TIMEOUT_MS, Toasts};
use crate::json::Json;
use crate::mc::Mc;
use crate::settings_page;
use crate::store;

const KEY: &str = "loadBalancing";

/// How often a machine gets new threads, as the MC's weight for it.
struct Preference {
    weight: i64,
    label: &'static str,
}

const PREFERENCES: [Preference; 4] = [
    Preference {
        weight: 100,
        label: "Prefer",
    },
    Preference {
        weight: 50,
        label: "Normal",
    },
    Preference {
        weight: 25,
        label: "Less often",
    },
    Preference {
        weight: 0,
        label: "Manual only",
    },
];

fn at(weight: i64) -> &'static Preference {
    PREFERENCES
        .iter()
        .find(|p| p.weight == weight)
        .unwrap_or(&PREFERENCES[1])
}

/// The preference a saved weight shows as. A machine with none is at
/// Normal; a weight from an older build, which stored a slider's value,
/// snaps to the choice on its side of Normal, and only 0 is Manual only:
/// any other weight still gets threads.
fn preference_for(saved: Option<&Json>) -> &'static Preference {
    let Some(weight) = saved.and_then(Json::as_f64) else {
        return at(50);
    };
    if weight == 50.0 {
        at(50)
    } else if weight == 0.0 {
        at(0)
    } else if weight < 50.0 {
        at(25)
    } else {
        at(100)
    }
}

pub struct LoadBalancing {
    bridge: Bridge,
    me: Me<LoadBalancing>,
    mc: std::rc::Rc<dyn Mc>,
    active: bool,
}

impl Controller for LoadBalancing {
    fn new(init: Init<'_, Self>) -> Self {
        LoadBalancing {
            bridge: init.bridge,
            me: init.me,
            mc: init.mc,
            active: false,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let me = self.me.clone();
        store::on_changed(engine, move |engine| {
            me.run(engine, |c, engine| c.publish(engine));
        });
        let me = self.me.clone();
        Settings::of(engine).on_settings_changed(move |engine| {
            me.run(engine, |c, engine| c.publish(engine));
        });
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !self.active || !action.starts_with("loadBalancing.") {
            return false;
        }
        match action {
            "loadBalancing.enable" => {
                let enabled = settings_page::flag(payload.get("enabled"));
                save(engine, move |mut document| {
                    document.insert("loadBalancingEnabled".into(), json!(enabled));
                    document
                });
            }
            "loadBalancing.prefer" => {
                let environment_id = settings_page::text(payload, "environmentId").to_owned();
                let weight = settings_page::int(payload.get("weight"));
                let offered = PREFERENCES.iter().any(|p| p.weight == weight);
                if environment_id.is_empty() || !offered {
                    return true;
                }
                save(engine, move |mut document| {
                    let mut weights = document
                        .get("loadBalancingWeights")
                        .and_then(Json::as_object)
                        .cloned()
                        .unwrap_or_default();
                    weights.insert(environment_id.clone(), json!(weight));
                    document.insert("loadBalancingWeights".into(), Json::Object(weights));
                    document
                });
            }
            _ => {}
        }
        true
    }
}

fn save(engine: &Engine, edit: impl Fn(Map) -> Map + 'static) {
    Settings::of(engine).change(
        engine,
        move |document| edit(document.clone()),
        |engine, error| {
            if let Some(error) = error {
                controller::with::<Toasts, _>(engine, |toasts, engine| {
                    toasts.show(
                        engine,
                        "error",
                        "Setting not saved",
                        &error,
                        None,
                        DEFAULT_TIMEOUT_MS,
                    );
                });
            }
        },
    );
}

impl LoadBalancing {
    fn publish(&self, engine: &Engine) {
        if !self.active {
            return;
        }
        let scope = SettingsScope::of(engine);
        let local = self.mc.environment();
        let mut machines = store::with(engine, |s| s.environments());
        machines.sort();
        machines.dedup();
        if machines.len() < 2 {
            self.bridge.publish(engine, KEY, Json::Null);
            return;
        }
        // This machine first, the rest by name.
        // TODO(port): Qt compared with QString::localeAwareCompare; this is
        // a plain lowercase compare.
        let mut named: Vec<(String, String)> = machines
            .into_iter()
            .map(|id| (scope.label(engine, &id), id))
            .collect();
        named.sort_by(|(a_label, a), (b_label, b)| {
            ((b == &local).cmp(&(a == &local)))
                .then_with(|| a_label.to_lowercase().cmp(&b_label.to_lowercase()))
        });
        let settings = Settings::of(engine);
        let document = settings.settings();
        let enabled = document
            .get("loadBalancingEnabled")
            .and_then(Json::as_bool)
            .unwrap_or(false);
        let weights = document
            .get("loadBalancingWeights")
            .and_then(Json::as_object)
            .cloned()
            .unwrap_or_default();
        let mut rows = Vec::new();
        let mut changed = Vec::new();
        for (label, id) in &named {
            let preference = preference_for(weights.get(id));
            rows.push(json!({"environmentId": id, "label": label, "weight": preference.weight}));
            if preference.weight != 50 {
                changed.push(format!("{label} {}", preference.label.to_lowercase()));
            }
        }
        let offered: Vec<Json> = PREFERENCES
            .iter()
            .map(|p| json!({"weight": p.weight, "label": p.label}))
            .collect();
        self.bridge.publish(
            engine,
            KEY,
            json!({
                "ready": settings.ready(),
                "enabled": enabled,
                "summary": if enabled { changed.join(" · ") } else { "Off".to_owned() },
                "preferences": offered,
                "machines": rows,
            }),
        );
    }
}
