//! An instance's custom models (`config.customModels`: bare slugs or
//! `{slug, name, capabilities {optionDescriptors}}`), desktop-qt's
//! `ProviderCustomModels`. The editor edits options as `[{id, label, type:
//! select | boolean, choices [{id, label, isDefault}]}]`.

use std::collections::BTreeSet;

use serde_json::json;

use crate::json::Json;

const MAX_SLUG_LENGTH: usize = 256;

fn text<'a>(object: &'a Json, key: &str) -> &'a str {
    object.get(key).and_then(Json::as_str).unwrap_or_default()
}

fn list<'a>(object: &'a Json, key: &str) -> &'a [Json] {
    object
        .get(key)
        .and_then(Json::as_array)
        .map_or(&[], Vec::as_slice)
}

fn choice(id: &str, label: &str, is_default: bool) -> Json {
    json!({"id": id, "label": label, "isDefault": is_default})
}

fn option(id: &str, label: &str, kind: &str, choices: Vec<Json>) -> Json {
    json!({"id": id, "label": label, "type": kind, "choices": choices})
}

fn effort(fallback: &str) -> Vec<Json> {
    vec![
        choice("low", "Low", fallback == "low"),
        choice("medium", "Medium", fallback == "medium"),
        choice("high", "High", fallback == "high"),
        choice("xhigh", "Extra High", false),
    ]
}

/// A stored descriptor as an editor option; `promptInjectedValues` are left
/// out.
fn editor_option(descriptor: &Json) -> Json {
    let kind = if text(descriptor, "type") == "boolean" {
        "boolean"
    } else {
        "select"
    };
    let injected: BTreeSet<&str> = list(descriptor, "promptInjectedValues")
        .iter()
        .filter_map(Json::as_str)
        .collect();
    let options: Vec<&Json> = list(descriptor, "options")
        .iter()
        .filter(|o| !injected.contains(text(o, "id")))
        .collect();
    let current = text(descriptor, "currentValue");
    let chosen = options
        .iter()
        .find(|o| !current.is_empty() && text(o, "id") == current)
        .map(|_| current)
        .or_else(|| {
            options
                .iter()
                .find(|o| o.get("isDefault").and_then(Json::as_bool) == Some(true))
                .map(|o| text(o, "id"))
        })
        .unwrap_or_default();
    let choices = if kind == "select" {
        options
            .iter()
            .map(|o| {
                let id = text(o, "id");
                choice(id, text(o, "label"), !chosen.is_empty() && id == chosen)
            })
            .collect()
    } else {
        Vec::new()
    };
    option(
        text(descriptor, "id"),
        text(descriptor, "label"),
        kind,
        choices,
    )
}

fn editor_options(capabilities: &Json, driver: &str) -> Vec<Json> {
    list(capabilities, "optionDescriptors")
        .iter()
        // Claude's context choices need runtime suffixes a custom model does
        // not carry.
        .filter(|d| !(driver == "claudeAgent" && text(d, "id") == "contextWindow"))
        .map(editor_option)
        .collect()
}

/// The saved models, first of each slug: `[{slug, name ("" when it is the
/// slug), options}]`.
pub fn read(setting: &Json) -> Json {
    let mut seen = BTreeSet::new();
    let mut result = Vec::new();
    let entries = setting.as_array().map_or(&[][..], Vec::as_slice);
    for value in entries {
        let slug = match value {
            Json::String(slug) => slug.trim(),
            other => text(other, "slug").trim(),
        };
        if slug.is_empty() || !seen.insert(slug) {
            continue;
        }
        let name = text(value, "name").trim();
        let empty = json!({});
        let capabilities = value.get("capabilities").unwrap_or(&empty);
        result.push(json!({
            "slug": slug,
            "name": if name == slug { "" } else { name },
            "options": editor_options(capabilities, ""),
        }));
    }
    Json::Array(result)
}

/// Why `slug` cannot be added next to the provider's `models` and the saved
/// `setting`, or empty.
pub fn refusal(slug: &str, models: &[Json], setting: &Json) -> String {
    let slug = slug.trim();
    if slug.is_empty() {
        return "Enter a model slug.".into();
    }
    let built_in = |m: &&Json| {
        m.get("isCustom").and_then(Json::as_bool) != Some(true) && text(m, "slug") == slug
    };
    if models.iter().any(|m| built_in(&m)) {
        return "That model is already built in.".into();
    }
    if slug.encode_utf16().count() > MAX_SLUG_LENGTH {
        return format!("Model slugs must be {MAX_SLUG_LENGTH} characters or less.");
    }
    if read(setting)
        .as_array()
        .is_some_and(|saved| saved.iter().any(|m| text(m, "slug") == slug))
    {
        return "That custom model is already saved.".into();
    }
    String::new()
}

/// The first problem with `options` in reading order ("Option 1 needs an
/// id."), or empty.
pub fn problem(options: &[Json]) -> String {
    let mut ids = BTreeSet::new();
    for (index, option) in options.iter().enumerate() {
        let position = format!("Option {}", index + 1);
        let id = text(option, "id").trim();
        if id.is_empty() {
            return format!("{position} needs an id.");
        }
        if !ids.insert(id) {
            return format!("{position}: id \"{id}\" is used twice.");
        }
        if text(option, "label").trim().is_empty() {
            return format!("{position} needs a label.");
        }
        if text(option, "type") == "boolean" {
            continue;
        }
        let choices = list(option, "choices");
        if choices.is_empty() {
            return format!("{position} needs at least one choice.");
        }
        let mut seen = BTreeSet::new();
        for value in choices {
            let id = text(value, "id").trim();
            if id.is_empty() {
                return format!("{position} has a choice without a value.");
            }
            if !seen.insert(id) {
                return format!("{position}: choice \"{id}\" is used twice.");
            }
        }
    }
    String::new()
}

/// The stored setting for a model: its bare slug without a name or options.
pub fn setting(slug: &str, name: &str, options: &[Json]) -> Json {
    let name = name.trim();
    let mut descriptors = Vec::new();
    for option in options {
        let mut descriptor = json!({
            "id": text(option, "id").trim(),
            "label": text(option, "label").trim(),
        });
        if text(option, "type") == "boolean" {
            descriptor["type"] = json!("boolean");
        } else {
            descriptor["type"] = json!("select");
            let mut choices = Vec::new();
            let mut current = "";
            for choice in list(option, "choices") {
                let id = text(choice, "id").trim();
                let label = text(choice, "label").trim();
                let mut stored =
                    json!({"id": id, "label": if label.is_empty() { id } else { label }});
                // Only one choice is the default.
                if choice.get("isDefault").and_then(Json::as_bool) == Some(true)
                    && current.is_empty()
                {
                    stored["isDefault"] = json!(true);
                    current = id;
                }
                choices.push(stored);
            }
            descriptor["options"] = Json::Array(choices);
            if !current.is_empty() {
                descriptor["currentValue"] = json!(current);
            }
        }
        descriptors.push(descriptor);
    }
    if (name.is_empty() || name == slug) && descriptors.is_empty() {
        return json!(slug);
    }
    let mut entry = json!({"slug": slug});
    if !name.is_empty() && name != slug {
        entry["name"] = json!(name);
    }
    if !descriptors.is_empty() {
        entry["capabilities"] = json!({"optionDescriptors": descriptors});
    }
    entry
}

/// The options a driver's adapter reads, with their usual choices.
pub fn presets(driver: &str) -> Json {
    let with = |extra: Json, choices: &mut Vec<Json>| {
        choices.push(extra);
        choices.clone()
    };
    let select = |id, label, choices| option(id, label, "select", choices);
    let flag = |id, label| option(id, label, "boolean", Vec::new());
    let options = match driver {
        "codex" => vec![
            select("reasoningEffort", "Reasoning", effort("medium")),
            select(
                "serviceTier",
                "Speed",
                vec![
                    choice("default", "Standard", true),
                    choice("fast", "Fast", false),
                ],
            ),
        ],
        "claudeAgent" => vec![
            select(
                "effort",
                "Reasoning",
                with(choice("max", "Max", false), &mut effort("high")),
            ),
            flag("fastMode", "Fast Mode"),
            flag("thinking", "Thinking"),
        ],
        "cursor" => vec![
            select("reasoning", "Reasoning", effort("medium")),
            flag("fastMode", "Fast Mode"),
            flag("thinking", "Thinking"),
        ],
        "grok" => vec![select("reasoningEffort", "Reasoning", effort("medium"))],
        "pi" => vec![select(
            "thinking",
            "Thinking",
            vec![
                choice("off", "Off", false),
                choice("minimal", "Minimal", false),
                choice("low", "Low", false),
                choice("medium", "Medium", true),
                choice("high", "High", false),
                choice("xhigh", "Extra High", false),
                choice("max", "Max", false),
            ],
        )],
        // Muse's fallback tiers for a model its catalog does not describe.
        "muse" => vec![select(
            "reasoningEffort",
            "Reasoning",
            with(choice("max", "Max", false), &mut effort("high")),
        )],
        "opencode" => vec![
            select("variant", "Reasoning", effort("medium")),
            select(
                "agent",
                "Agent",
                vec![
                    choice("build", "Build", true),
                    choice("plan", "Plan", false),
                ],
            ),
        ],
        _ => Vec::new(),
    };
    Json::Array(options)
}

/// The provider's own models with options, as editor options to copy from:
/// `[{slug, name, options}]`. Claude's context window is left out, and
/// choices delivered as prompt text.
pub fn copyable(models: &[Json], driver: &str) -> Json {
    let mut result = Vec::new();
    for model in models {
        if model.get("isCustom").and_then(Json::as_bool) == Some(true) {
            continue;
        }
        let empty = json!({});
        let options = editor_options(model.get("capabilities").unwrap_or(&empty), driver);
        if options.is_empty() {
            continue;
        }
        let slug = text(model, "slug");
        let name = text(model, "name");
        result.push(json!({
            "slug": slug,
            "name": if name.is_empty() { slug } else { name },
            "options": options,
        }));
    }
    Json::Array(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn array(value: &Json) -> &[Json] {
        value.as_array().unwrap()
    }

    #[test]
    fn saved_models_read_as_slugs_names_and_options() {
        let saved = read(&json!([
            "plain",
            " plain ",
            {"slug": "named", "name": " Named "},
            {"slug": "same", "name": "same"},
            {"slug": ""},
            7,
            {"slug": "tuned", "capabilities": {"optionDescriptors": [
                {"id": "effort", "label": "Reasoning", "type": "select", "currentValue": "high",
                 "options": [{"id": "low", "label": "Low", "isDefault": true},
                             {"id": "high", "label": "High"},
                             {"id": "ultra", "label": "Ultra"}],
                 "promptInjectedValues": ["ultra"]},
                {"id": "fast", "label": "Fast", "type": "boolean"},
            ]}},
        ]));
        let saved = array(&saved);
        let slugs: Vec<_> = saved.iter().map(|m| m["slug"].as_str().unwrap()).collect();
        assert_eq!(slugs, ["plain", "named", "same", "tuned"]);
        assert_eq!(saved[1]["name"], "Named");
        assert_eq!(saved[2]["name"], "");
        let options = array(&saved[3]["options"]);
        // The current value is the chosen one, ahead of the descriptor's
        // default; prompt-injected choices are not offered.
        assert_eq!(
            options[0],
            json!({"id": "effort", "label": "Reasoning", "type": "select", "choices": [
                {"id": "low", "label": "Low", "isDefault": false},
                {"id": "high", "label": "High", "isDefault": true},
            ]})
        );
        assert_eq!(options[1]["type"], "boolean");
        assert_eq!(options[1]["choices"], json!([]));
    }

    #[test]
    fn a_descriptor_with_no_current_value_starts_from_its_default() {
        let saved = read(
            &json!([{"slug": "m", "capabilities": {"optionDescriptors": [
                {"id": "e", "label": "E", "options": [{"id": "a", "label": "A"}, {"id": "b", "label": "B", "isDefault": true}]},
            ]}}]),
        );
        let choices = &saved[0]["options"][0]["choices"];
        assert_eq!(choices[0]["isDefault"], false);
        assert_eq!(choices[1]["isDefault"], true);
    }

    #[test]
    fn a_slug_is_refused_for_the_reason_it_cannot_be_added() {
        let models = [
            json!({"slug": "gpt-5", "isCustom": false}),
            json!({"slug": "mine", "isCustom": true}),
        ];
        let saved = json!(["saved"]);
        assert_eq!(refusal("  ", &models, &saved), "Enter a model slug.");
        assert_eq!(
            refusal("gpt-5", &models, &saved),
            "That model is already built in."
        );
        assert_eq!(
            refusal("saved", &models, &saved),
            "That custom model is already saved."
        );
        assert_eq!(
            refusal(&"x".repeat(257), &models, &saved),
            "Model slugs must be 256 characters or less."
        );
        // A custom model of the provider's list is not a built-in one.
        assert_eq!(refusal("mine", &models, &saved), "");
        assert_eq!(refusal(" fresh ", &models, &saved), "");
    }

    #[test]
    fn the_first_problem_with_the_options_is_named() {
        let boolean = |id: &str, label: &str| json!({"id": id, "label": label, "type": "boolean"});
        let select = |id: &str, choices: Json| json!({"id": id, "label": "L", "type": "select", "choices": choices});
        assert_eq!(problem(&[]), "");
        assert_eq!(problem(&[boolean(" ", "L")]), "Option 1 needs an id.");
        assert_eq!(
            problem(&[boolean("a", "L"), boolean("a", "L")]),
            "Option 2: id \"a\" is used twice."
        );
        assert_eq!(problem(&[boolean("a", " ")]), "Option 1 needs a label.");
        assert_eq!(
            problem(&[select("a", json!([]))]),
            "Option 1 needs at least one choice."
        );
        assert_eq!(
            problem(&[select("a", json!([{"id": ""}]))]),
            "Option 1 has a choice without a value."
        );
        assert_eq!(
            problem(&[select("a", json!([{"id": "x"}, {"id": " x "}]))]),
            "Option 1: choice \"x\" is used twice."
        );
        assert_eq!(
            problem(&[boolean("a", "L"), select("b", json!([{"id": "x"}]))]),
            ""
        );
    }

    #[test]
    fn a_model_without_a_name_or_options_is_stored_as_its_slug() {
        assert_eq!(setting("m", "", &[]), json!("m"));
        assert_eq!(setting("m", " m ", &[]), json!("m"));
        assert_eq!(
            setting("m", " Name ", &[]),
            json!({"slug": "m", "name": "Name"})
        );
    }

    #[test]
    fn options_are_stored_as_descriptors_with_one_default() {
        let options = [
            json!({"id": " e ", "label": " Effort ", "type": "select", "choices": [
                {"id": "a", "label": "", "isDefault": true},
                {"id": "b", "label": "B", "isDefault": true},
            ]}),
            json!({"id": "f", "label": "Fast", "type": "boolean"}),
        ];
        assert_eq!(
            setting("m", "m", &options),
            json!({"slug": "m", "capabilities": {"optionDescriptors": [
                {"id": "e", "label": "Effort", "type": "select", "currentValue": "a", "options": [
                    {"id": "a", "label": "a", "isDefault": true},
                    {"id": "b", "label": "B"},
                ]},
                {"id": "f", "label": "Fast", "type": "boolean"},
            ]}})
        );
    }

    #[test]
    fn what_the_editor_stores_it_reads_back() {
        let stored = setting("m", "Mine", array(&presets("claudeAgent")));
        let read = read(&json!([stored]));
        assert_eq!(read[0]["name"], "Mine");
        assert_eq!(read[0]["options"], presets("claudeAgent"));
        assert_eq!(problem(array(&read[0]["options"])), "");
    }

    #[test]
    fn each_driver_has_its_presets() {
        for (driver, ids) in [
            ("codex", vec!["reasoningEffort", "serviceTier"]),
            ("claudeAgent", vec!["effort", "fastMode", "thinking"]),
            ("cursor", vec!["reasoning", "fastMode", "thinking"]),
            ("grok", vec!["reasoningEffort"]),
            ("pi", vec!["thinking"]),
            ("muse", vec!["reasoningEffort"]),
            ("opencode", vec!["variant", "agent"]),
            ("antigravity", vec![]),
            ("acpRegistry", vec![]),
        ] {
            let presets = presets(driver);
            let found: Vec<_> = array(&presets)
                .iter()
                .map(|o| o["id"].as_str().unwrap())
                .collect();
            assert_eq!(found, ids, "{driver}");
        }
        // Claude and Muse reason up to max, defaulting to high.
        let claude = presets("claudeAgent");
        let choices = array(&claude[0]["choices"]);
        assert_eq!(choices.last().unwrap()["id"], "max");
        assert_eq!(
            choices
                .iter()
                .filter(|c| c["isDefault"] == true)
                .map(|c| &c["id"])
                .collect::<Vec<_>>(),
            [&json!("high")]
        );
        // Codex's effort defaults to medium, and the drivers' form agrees.
        assert_eq!(
            array(&presets("codex")[0]["choices"])
                .iter()
                .find(|c| c["isDefault"] == true)
                .unwrap()["id"],
            "medium"
        );
        for driver in crate::provider::drivers::all() {
            let ids: Vec<_> = driver.options.iter().map(|o| o.id).collect();
            let found = presets(driver.id);
            let preset_ids: Vec<_> = array(&found)
                .iter()
                .map(|o| o["id"].as_str().unwrap())
                .collect();
            assert_eq!(preset_ids, ids, "{}", driver.id);
        }
    }

    #[test]
    fn the_providers_own_models_are_offered_to_copy_from() {
        let described = json!({"optionDescriptors": [
            {"id": "contextWindow", "label": "Context", "type": "select", "options": [{"id": "1m", "label": "1M"}]},
            {"id": "effort", "label": "Reasoning", "type": "select", "options": [{"id": "low", "label": "Low"}]},
        ]});
        let models = [
            json!({"slug": "opus", "name": "Opus", "capabilities": described}),
            json!({"slug": "mine", "isCustom": true, "capabilities": described}),
            json!({"slug": "plain", "name": "Plain"}),
            json!({"slug": "sonnet", "capabilities": described}),
        ];
        let copyable = copyable(&models, "claudeAgent");
        let copyable = array(&copyable);
        assert_eq!(copyable.len(), 2);
        assert_eq!(copyable[0]["name"], "Opus");
        assert_eq!(copyable[1]["name"], "sonnet");
        // Claude's context window is not copied; another driver's is.
        assert_eq!(array(&copyable[0]["options"]).len(), 1);
        assert_eq!(
            array(&super::copyable(&models, "codex")[0]["options"]).len(),
            2
        );
    }
}
