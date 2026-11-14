//! `textGeneration`, desktop-qt's TextGenerationController: Settings →
//! General, Text generation. The model that writes thread titles and other
//! generated text on the selected environments
//! (`textGenerationModelSelection`, a project's override at project scope).
//! A choice is written to every selected environment, so each must offer the
//! model.
//!
//! Publishes `textGeneration`: {open, value ("<instance>:<model>", "" when
//! mixed), label, mixed, resettable, models: [{key, label}] (the first
//! selected environment's text generation providers'), unavailable (why no
//! model can be chosen, "" when one can)}.
//!
//! Actions: `textGeneration.choose {key}`, `textGeneration.reset`.

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::settings::Map;
use crate::controllers::settings_scope::SettingsScope;
use crate::controllers::toasts::Toasts;
use crate::json::Json;
use crate::settings_page;

const KEY: &str = "textGeneration";
const SETTING: &str = "textGenerationModelSelection";
const TITLE: &str = "Text generation model not saved";

fn text<'a>(object: &'a Json, key: &str) -> &'a str {
    settings_page::text(object, key)
}

/// The providers that can write text and can be used now.
fn usable(providers: Vec<Json>) -> Vec<Json> {
    providers
        .into_iter()
        .filter(|p| {
            p.get("supportsTextGeneration") != Some(&Json::Bool(false))
                && p.get("enabled").and_then(Json::as_bool).unwrap_or(true)
                && p.get("installed").and_then(Json::as_bool).unwrap_or(true)
                && text(p, "availability") != "unavailable"
        })
        .collect()
}

fn offers(providers: Vec<Json>, instance_id: &str, model: &str) -> bool {
    usable(providers).iter().any(|p| {
        text(p, "instanceId") == instance_id
            && p.get("models")
                .and_then(Json::as_array)
                .is_some_and(|models| models.iter().any(|m| text(m, "slug") == model))
    })
}

fn key_of(selection: &Json) -> String {
    match selection.as_object() {
        Some(o) if !o.is_empty() => format!(
            "{}:{}",
            text(selection, "instanceId"),
            text(selection, "model")
        ),
        _ => String::new(),
    }
}

/// The project's own choice, else the environment's; None when neither is
/// set.
fn stored(settings: &Map, project_id: &str) -> Option<Json> {
    if !project_id.is_empty()
        && let Some(own) = SettingsScope::override_of(settings, project_id, SETTING)
    {
        return Some(own);
    }
    settings.get(SETTING).cloned()
}

pub struct TextGeneration {
    bridge: Bridge,
    me: Me<TextGeneration>,
    active: bool,
    open: bool,
}

impl Controller for TextGeneration {
    fn new(init: Init<'_, Self>) -> Self {
        TextGeneration {
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
        if !self.active || !action.starts_with("textGeneration.") {
            return false;
        }
        match action {
            "textGeneration.choose" => self.choose(engine, settings_page::text(payload, "key")),
            "textGeneration.reset" => self.write(engine, None),
            _ => {}
        }
        true
    }
}

impl TextGeneration {
    fn set_open(&mut self, engine: &Engine, open: bool) {
        self.open = open;
        self.publish(engine);
    }

    fn choose(&self, engine: &Engine, key: &str) {
        let Some((instance_id, model)) = key.split_once(':').filter(|(i, _)| !i.is_empty()) else {
            return;
        };
        let scope = SettingsScope::of(engine);
        // It goes to every selected environment, so each must offer it.
        for environment in scope.targets() {
            if offers(scope.providers(&environment), instance_id, model) {
                continue;
            }
            let description = format!(
                "This model is unavailable on {}. Select that environment to choose its model separately.",
                scope.label(engine, &environment)
            );
            controller::with::<Toasts, _>(engine, |toasts, engine| {
                toasts.error(engine, TITLE, &description);
            });
            // The row goes back to what is saved.
            self.publish(engine);
            return;
        }
        self.write(
            engine,
            Some(json!({"instanceId": instance_id, "model": model})),
        );
    }

    /// Sets the choice on every target; None resets it.
    fn write(&self, engine: &Engine, value: Option<Json>) {
        SettingsScope::of(engine).write(
            engine,
            move |mut settings, project_id| {
                if !project_id.is_empty() {
                    return SettingsScope::with_override(
                        settings,
                        project_id,
                        SETTING,
                        value.clone(),
                    );
                }
                match &value {
                    Some(value) => settings.insert(SETTING.into(), value.clone()),
                    None => settings.remove(SETTING),
                };
                settings
            },
            TITLE,
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
        let scope = SettingsScope::of(engine);
        let targets = scope.targets();
        let reading = scope.read(|settings, project_id| {
            Some(
                stored(settings, project_id)
                    .filter(Json::is_object)
                    .unwrap_or(Json::Null),
            )
        });
        let customised = scope.read(|settings, project_id| {
            Some(Json::Bool(if project_id.is_empty() {
                settings.contains_key(SETTING)
            } else {
                SettingsScope::override_of(settings, project_id, SETTING).is_some()
            }))
        });
        let key = if reading.mixed {
            String::new()
        } else {
            key_of(reading.value.as_ref().unwrap_or(&Json::Null))
        };
        let providers = targets
            .first()
            .map(|first| usable(scope.providers(first)))
            .unwrap_or_default();
        let mut models = Vec::new();
        let mut label = String::new();
        for provider in &providers {
            let name = match text(provider, "displayName") {
                "" => text(provider, "instanceId"),
                name => name,
            };
            let slugs = provider
                .get("models")
                .and_then(Json::as_array)
                .map(Vec::as_slice)
                .unwrap_or_default();
            for model in slugs {
                if model
                    .get("isLegacy")
                    .and_then(Json::as_bool)
                    .unwrap_or(false)
                {
                    continue;
                }
                let model_key = format!("{}:{}", text(provider, "instanceId"), text(model, "slug"));
                let shown = format!(
                    "{name} · {}",
                    match text(model, "name") {
                        "" => text(model, "slug"),
                        n => n,
                    }
                );
                if model_key == key {
                    label = shown.clone();
                }
                models.push(json!({"key": model_key, "label": shown}));
            }
        }
        let unavailable = if targets.is_empty() {
            "Connect an environment to choose its text generation model."
        } else if models.is_empty() {
            "No text generation providers available."
        } else {
            ""
        };
        let label = if reading.mixed {
            "Mixed".to_owned()
        } else if label.is_empty() {
            // Unset, an environment uses its default; a saved model no
            // provider offers still names itself.
            if key.is_empty() {
                "Default".to_owned()
            } else {
                format!("{key} (Unavailable)")
            }
        } else {
            label
        };
        self.bridge.publish(
            engine,
            KEY,
            json!({
                "open": true,
                "value": key,
                "label": label,
                "mixed": reading.mixed,
                "resettable": customised.mixed || customised.value.as_ref().and_then(Json::as_bool).unwrap_or(false),
                "models": models,
                "unavailable": unavailable,
            }),
        );
    }
}
