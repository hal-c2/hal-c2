//! Provider instances in an environment's settings document, as the MC reads
//! them (HalC2.Acp instance/setting, HalC2.ProviderSecrets), desktop-qt's
//! `ProviderInstances`: each instance's `providerInstances.<id>` entry
//! `{driver, enabled, displayName, accentColor, config, environment [{name,
//! value, sensitive, valueRedacted}]}`, and for a built-in's own slot (the id
//! is the driver) the `providers.<driver>` entry it falls back to.

use std::collections::BTreeSet;

use serde_json::{Map, json};

use crate::json::Json;

fn object(value: Option<&Json>) -> Map<String, Json> {
    value.and_then(Json::as_object).cloned().unwrap_or_default()
}

/// The instance as the MC reads it: its own entry, or for a built-in's own
/// slot one made from `providers.<driver>`.
pub fn of(settings: &Json, id: &str, driver: &str) -> Json {
    if let Some(instance) = settings.get("providerInstances").and_then(|i| i.get(id)) {
        return Json::Object(object(Some(instance)));
    }
    let mut instance = json!({ "driver": driver });
    if id != driver {
        return instance;
    }
    let mut config = object(settings.get("providers").and_then(|p| p.get(driver)));
    if let Some(enabled) = config.remove("enabled") {
        instance["enabled"] = enabled;
    }
    if !config.is_empty() {
        instance["config"] = Json::Object(config);
    }
    instance
}

/// `settings` with the instance's entry replaced; an empty one removes it.
pub fn with(settings: Json, id: &str, instance: Json) -> Json {
    let mut instances = object(settings.get("providerInstances"));
    if instance.as_object().is_none_or(Map::is_empty) {
        instances.remove(id);
    } else {
        instances.insert(id.into(), instance);
    }
    let mut root = object(Some(&settings));
    root.insert("providerInstances".into(), Json::Object(instances));
    Json::Object(root)
}

/// `instance` with `config.<key>` set; an empty string or null removes it.
pub fn with_config(instance: Json, key: &str, value: &Json) -> Json {
    let mut root = object(Some(&instance));
    let mut config = object(root.get("config"));
    match value {
        Json::Null => {
            config.remove(key);
        }
        Json::String(s) if s.trim().is_empty() => {
            config.remove(key);
        }
        Json::String(s) => {
            config.insert(key.into(), Json::String(s.trim().into()));
        }
        other => {
            config.insert(key.into(), other.clone());
        }
    }
    if config.is_empty() {
        root.remove("config");
    } else {
        root.insert("config".into(), Json::Object(config));
    }
    Json::Object(root)
}

/// Ids a new instance may not take: Codex's and Claude's own slots,
/// configured instances and providers, and the instances the environment
/// lists (`providers`, its provider statuses).
pub fn taken(settings: &Json, providers: &[Json]) -> BTreeSet<String> {
    let mut ids: BTreeSet<String> = ["codex", "claudeAgent"].map(String::from).into();
    for section in ["providerInstances", "providers"] {
        ids.extend(object(settings.get(section)).keys().cloned());
    }
    for provider in providers {
        if let Some(id) = provider.get("instanceId").and_then(Json::as_str) {
            ids.insert(id.into());
        }
    }
    ids.remove("");
    ids
}

/// `#rrggbb` in lower case, or empty for anything else.
pub fn accent(color: &str) -> String {
    let color = color.trim();
    match color.strip_prefix('#') {
        Some(hex) if hex.len() == 6 && hex.chars().all(|c| c.is_ascii_hexdigit()) => {
            color.to_ascii_lowercase()
        }
        _ => String::new(),
    }
}

/// An environment variable name (ENVIRONMENT_VARIABLE_NAME_PATTERN).
pub fn valid_variable_name(name: &str) -> bool {
    let mut chars = name.chars();
    chars
        .next()
        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn settings() -> Json {
        json!({
            "providerInstances": {
                "codex_work": {"driver": "codex", "enabled": true, "config": {"homePath": "~/work"}},
                "broken": 3,
            },
            "providers": {"codex": {"enabled": false, "binaryPath": "/opt/codex"}, "grok": {}},
        })
    }

    #[test]
    fn an_instance_reads_as_its_own_entry() {
        assert_eq!(
            of(&settings(), "codex_work", "codex")["config"]["homePath"],
            "~/work"
        );
        // An entry that is no object is an empty one.
        assert_eq!(of(&settings(), "broken", "codex"), json!({}));
    }

    #[test]
    fn a_built_ins_own_slot_falls_back_to_its_providers_entry() {
        assert_eq!(
            of(&settings(), "codex", "codex"),
            json!({"driver": "codex", "enabled": false, "config": {"binaryPath": "/opt/codex"}})
        );
        assert_eq!(of(&settings(), "grok", "grok"), json!({"driver": "grok"}));
        assert_eq!(
            of(&settings(), "claudeAgent", "claudeAgent"),
            json!({"driver": "claudeAgent"})
        );
        // Only the driver's own slot falls back.
        assert_eq!(
            of(&settings(), "codex_new", "codex"),
            json!({"driver": "codex"})
        );
    }

    #[test]
    fn an_instance_is_replaced_and_an_empty_one_removed() {
        let next = with(settings(), "codex_new", json!({"driver": "codex"}));
        assert_eq!(
            next["providerInstances"]["codex_new"],
            json!({"driver": "codex"})
        );
        assert_eq!(next["providers"], settings()["providers"]);
        let next = with(next, "codex_work", json!({}));
        assert!(next["providerInstances"].get("codex_work").is_none());
        assert!(
            with(json!({}), "x", json!({"driver": "grok"}))["providerInstances"]["x"].is_object()
        );
    }

    #[test]
    fn config_is_set_trimmed_and_removed_when_empty() {
        let instance = json!({"driver": "codex"});
        let set = with_config(instance, "binaryPath", &json!("  /bin/codex "));
        assert_eq!(set["config"]["binaryPath"], "/bin/codex");
        let set = with_config(set, "autoCompactWindow", &json!(300000));
        assert_eq!(set["config"]["autoCompactWindow"], 300000);
        let set = with_config(set, "binaryPath", &json!("   "));
        assert!(set["config"].get("binaryPath").is_none());
        let set = with_config(set, "autoCompactWindow", &Json::Null);
        assert_eq!(set, json!({"driver": "codex"}));
    }

    #[test]
    fn taken_ids_come_from_every_place_an_instance_can_be() {
        let providers = [
            json!({"instanceId": "cursor"}),
            json!({"instanceId": ""}),
            json!({}),
        ];
        let ids = taken(&settings(), &providers);
        assert_eq!(
            ids.into_iter().collect::<Vec<_>>(),
            [
                "broken",
                "claudeAgent",
                "codex",
                "codex_work",
                "cursor",
                "grok"
            ]
        );
    }

    #[test]
    fn an_accent_is_a_lower_case_hex_colour_or_nothing() {
        assert_eq!(accent(" #A1B2C3 "), "#a1b2c3");
        for bad in ["", "red", "#abc", "#abcdeg", "a1b2c3", "#a1b2c3d"] {
            assert_eq!(accent(bad), "", "{bad}");
        }
    }

    #[test]
    fn a_variable_name_is_letters_digits_and_underscores() {
        assert!(valid_variable_name("CURSOR_API_KEY"));
        assert!(valid_variable_name("_x1"));
        for bad in ["", "1X", "A-B", "A B", "É"] {
            assert!(!valid_variable_name(bad), "{bad}");
        }
    }
}
