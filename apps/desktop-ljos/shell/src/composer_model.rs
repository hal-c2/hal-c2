//! What the composer offers, worked out from the MC's own words: the
//! provider instances and models of the environment's config (`providers`),
//! this device's favourites and model order, the model's options, the
//! permission modes, what Enter sends, and the @, $ and / suggestions. Pure
//! functions, which the composer controller publishes (desktop-qt's
//! ComposerModel).
//!
//! Positions in the text (a cursor, a trigger's span) are UTF-16 units, as
//! QML's `TextEdit.cursorPosition` is.

use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::sync::LazyLock;

use regex::Regex;
use serde_json::{Map, json};
use unicode_general_category::{GeneralCategory, get_general_category};

use crate::json::Json;
use crate::keybindings::{self, Binding, Context};
use crate::thread_view::summary::{self, Obj, as_object, flag, object, text};

/// One provider instance of the config's `providers`, as the picker lists it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Instance {
    pub instance_id: String,
    pub driver: String,
    pub display_name: String,
    /// "#rrggbb" or empty.
    pub accent_color: String,
    /// An ACP registry icon, or empty.
    pub icon_url: String,
    pub status: String,
    pub message: String,
    pub enabled: bool,
    pub is_default: bool,
    pub available: bool,
    pub requires_new_thread_for_model_change: bool,
    pub show_interaction_mode_toggle: bool,
    /// supportedRuntimeModes; empty: all.
    pub runtime_modes: Vec<String>,
    pub models: Vec<Json>,
    pub slash_commands: Vec<Json>,
    /// ServerProviderUsageLimits, when the provider reports them.
    pub usage_limits: Obj,
    pub skills: Vec<Json>,
}

impl Instance {
    pub fn ready(&self) -> bool {
        self.enabled && self.available && self.status == "ready"
    }
}

fn array(object: &Obj, field: &str) -> Vec<Json> {
    object
        .get(field)
        .and_then(Json::as_array)
        .cloned()
        .unwrap_or_default()
}

/// The brand label a driver shows as.
fn brand_label(driver: &str) -> &'static str {
    match driver {
        "antigravity" => "Antigravity",
        "codex" => "Codex",
        "claudeAgent" | "claude" => "Claude",
        "cursor" => "Cursor",
        "grok" => "Grok",
        "acpRegistry" => "ACP Registry",
        "pi" => "Pi",
        "muse" => "Muse Code",
        "opencode" => "OpenCode",
        _ => "",
    }
}

/// "codexWork" and "codex_work" are "Codex Work".
pub fn humanize_slug(slug: &str) -> String {
    let mut spaced = String::new();
    let mut previous: Option<char> = None;
    for c in slug.chars() {
        if c == '_' || c == '-' {
            spaced.push(' ');
            previous = Some(c);
            continue;
        }
        if c.is_uppercase() && previous.is_some_and(char::is_lowercase) {
            spaced.push(' ');
        }
        spaced.push(c);
        previous = Some(c);
    }
    spaced
        .split_whitespace()
        .map(|word| {
            let mut chars = word.chars();
            chars
                .next()
                .map(|first| first.to_uppercase().chain(chars).collect::<String>())
                .unwrap_or_default()
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn display_name_of(provider: &Obj, instance_id: &str, driver: &str) -> String {
    let brand = match brand_label(driver) {
        "" => humanize_slug(driver),
        label => label.to_owned(),
    };
    let named = text(provider, "displayName").trim();
    if !named.is_empty() && named != brand {
        return named.to_owned();
    }
    if instance_id != driver {
        return humanize_slug(instance_id);
    }
    if named.is_empty() {
        brand
    } else {
        named.to_owned()
    }
}

/// "Claude Work" is "CW", "codex" is "CO".
pub fn initials_of(name: &str) -> String {
    let words: Vec<&str> = name
        .split(|c: char| c.is_whitespace() || c == '_' || c == '-')
        .filter(|w| !w.is_empty())
        .collect();
    let left = |word: &str, n: usize| word.chars().take(n).collect::<String>();
    match words.as_slice() {
        [] => String::new(),
        [one] => left(one, 2).to_uppercase(),
        [a, b, ..] => (left(a, 1) + &left(b, 1)).to_uppercase(),
    }
}

fn registry_icon(driver: &str, url: &str) -> String {
    if driver != "acpRegistry" || url.is_empty() {
        return String::new();
    }
    let Ok(parsed) = url::Url::parse(url) else {
        return String::new();
    };
    if parsed.scheme() != "https"
        || parsed.host_str() != Some("cdn.agentclientprotocol.com")
        || parsed.port().is_some()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
    {
        return String::new();
    }
    url.to_owned()
}

fn model_matches(model: &Obj, value: &str) -> bool {
    text(model, "slug") == value
        || text(model, "name").to_lowercase() == value.to_lowercase()
        || array(model, "aliases")
            .iter()
            .any(|alias| alias.as_str() == Some(value))
}

const ANTIGRAVITY_DEFAULT: &str = "antigravity-default";

fn keeps_unlisted_model(driver: &str) -> bool {
    driver == "opencode" || driver == "antigravity"
}

/// The instances, grouped by driver in first-seen order, defaults first.
pub fn instances(providers: &[Json]) -> Vec<Instance> {
    static HEX: LazyLock<Regex> = LazyLock::new(|| Regex::new("^#[0-9a-fA-F]{6}$").unwrap());
    let mut list = Vec::new();
    for value in providers {
        let provider = as_object(value);
        let instance_id = text(provider, "instanceId").to_owned();
        let driver = text(provider, "driver").to_owned();
        if instance_id.is_empty() || driver.is_empty() {
            continue;
        }
        let accent = text(provider, "accentColor");
        list.push(Instance {
            display_name: display_name_of(provider, &instance_id, &driver),
            accent_color: if HEX.is_match(accent) {
                accent.to_owned()
            } else {
                String::new()
            },
            icon_url: registry_icon(&driver, text(provider, "iconUrl")),
            status: text(provider, "status").to_owned(),
            message: text(provider, "message").to_owned(),
            enabled: flag(provider, "enabled"),
            is_default: instance_id == driver,
            available: text(provider, "availability") != "unavailable",
            requires_new_thread_for_model_change: flag(provider, "requiresNewThreadForModelChange"),
            show_interaction_mode_toggle: provider.get("showInteractionModeToggle")
                != Some(&Json::Bool(false)),
            runtime_modes: array(provider, "supportedRuntimeModes")
                .iter()
                .map(|mode| mode.as_str().unwrap_or("").to_owned())
                .collect(),
            models: array(provider, "models"),
            slash_commands: array(provider, "slashCommands"),
            usage_limits: object(provider, "usageLimits").clone(),
            skills: array(provider, "skills"),
            instance_id,
            driver,
        });
    }
    let mut drivers: Vec<String> = Vec::new();
    for instance in &list {
        if !drivers.contains(&instance.driver) {
            drivers.push(instance.driver.clone());
        }
    }
    let rank = |instance: &Instance| drivers.iter().position(|d| *d == instance.driver);
    list.sort_by(|a, b| {
        rank(a)
            .cmp(&rank(b))
            .then_with(|| b.is_default.cmp(&a.is_default))
    });
    list
}

pub fn find<'a>(list: &'a [Instance], instance_id: &str) -> Option<&'a Instance> {
    list.iter().find(|i| i.instance_id == instance_id)
}

/// The instance's model named by slug, name or alias; empty when none.
pub fn find_model(instance: &Instance, model: &str) -> Obj {
    if model.is_empty() {
        return Obj::new();
    }
    let models = || instance.models.iter().map(as_object);
    models()
        .find(|m| text(m, "slug") == model)
        .or_else(|| models().find(|m| model_matches(m, model)))
        .cloned()
        .unwrap_or_default()
}

/// The model a thread starts on with this instance: its default one.
pub fn default_model(instance: &Instance) -> String {
    let mut first_built_in = "";
    for model in instance.models.iter().map(as_object) {
        if flag(model, "isCustom") {
            continue;
        }
        if flag(model, "isDefault") {
            return text(model, "slug").to_owned();
        }
        if first_built_in.is_empty() {
            first_built_in = text(model, "slug");
        }
    }
    if !first_built_in.is_empty() {
        return first_built_in.to_owned();
    }
    instance
        .models
        .first()
        .map(|m| text(as_object(m), "slug").to_owned())
        .unwrap_or_default()
}

/// This device's model settings: `favorites` and `providerModelPreferences`.
#[derive(Clone, Debug, Default)]
pub struct ModelPrefs {
    /// instanceId + '\n' + slug.
    pub favorites: HashSet<String>,
    /// By instanceId: {hiddenModels, modelOrder}.
    pub preferences: Obj,
}

pub fn model_prefs(favorites: &Json, preferences: &Json) -> ModelPrefs {
    let favorites = favorites
        .as_array()
        .into_iter()
        .flatten()
        .map(|f| {
            let f = as_object(f);
            format!("{}\n{}", text(f, "provider"), text(f, "model"))
        })
        .collect();
    ModelPrefs {
        favorites,
        preferences: as_object(preferences).clone(),
    }
}

/// `favorites` with the model starred or unstarred.
pub fn toggle_favorite(favorites: &Json, instance_id: &str, model: &str) -> Json {
    let mut next = Vec::new();
    let mut removed = false;
    for value in favorites.as_array().into_iter().flatten() {
        let favorite = as_object(value);
        if text(favorite, "provider") == instance_id && text(favorite, "model") == model {
            removed = true;
            continue;
        }
        next.push(Json::Object(favorite.clone()));
    }
    if !removed {
        next.push(json!({"provider": instance_id, "model": model}));
    }
    Json::Array(next)
}

/// Why switching a started thread to `next` needs a new thread.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Block {
    pub title: String,
    pub description: String,
}

/// Why the model cannot change, for a session that started. Another
/// provider takes the thread over with its conversation handed across.
pub fn block_reason(
    list: &[Instance],
    current_instance: &str,
    current_model: &str,
    next_instance: &str,
    next_model: &str,
) -> Option<Block> {
    if current_instance != next_instance || current_model == next_model {
        return None;
    }
    let current = find(list, current_instance)?;
    current.requires_new_thread_for_model_change.then(|| Block {
        title: "Start a new chat to change models".into(),
        description:
            "This provider does not allow switching models after a conversation has started."
                .into(),
    })
}

/// The instance's models as the picker offers them (modelOptionsByInstance):
/// hidden ones out, the user's order, and the thread's model kept when the
/// provider no longer lists it.
fn model_options(
    instance: &Instance,
    prefs: &ModelPrefs,
    selected_instance: &str,
    selected_model: &str,
) -> Vec<Obj> {
    let preference = object(&prefs.preferences, &instance.instance_id);
    let hidden: HashSet<String> = array(preference, "hiddenModels")
        .iter()
        .map(|s| s.as_str().unwrap_or("").to_owned())
        .collect();
    let order: HashMap<String, usize> = array(preference, "modelOrder")
        .iter()
        .enumerate()
        .map(|(i, s)| (s.as_str().unwrap_or("").to_owned(), i))
        .collect();
    let mut models: Vec<Obj> = instance
        .models
        .iter()
        .map(as_object)
        .filter(|m| flag(m, "isCustom") || !hidden.contains(text(m, "slug")))
        .cloned()
        .collect();
    models.sort_by_key(|m| order.get(text(m, "slug")).copied().unwrap_or(usize::MAX));

    if keeps_unlisted_model(&instance.driver)
        && instance.instance_id == selected_instance
        && !selected_model.is_empty()
        && selected_model != ANTIGRAVITY_DEFAULT
        && !hidden.contains(selected_model)
    {
        let listed = instance
            .models
            .iter()
            .any(|m| model_matches(as_object(m), selected_model));
        if !listed {
            let unlisted =
                json!({"slug": selected_model, "name": selected_model, "isUnavailable": true});
            models.push(as_object(&unlisted).clone());
        }
    }
    models
}

/// Whether the picker offers this model.
fn offered(instance: &Instance, model: &Obj, active_instance: &str, active_model: &str) -> bool {
    let slug = text(model, "slug");
    if instance.driver == "antigravity" && slug == ANTIGRAVITY_DEFAULT {
        return false;
    }
    if instance.ready() {
        return true;
    }
    instance.enabled
        && keeps_unlisted_model(&instance.driver)
        && instance.instance_id == active_instance
        && slug == active_model
        && flag(model, "isUnavailable")
}

/// Why an instance cannot be used.
fn unavailable_reason(instance: &Instance) -> String {
    if !instance.enabled || instance.status == "disabled" {
        return format!("{} — Disabled in settings.", instance.display_name);
    }
    let kind = match instance.status.as_str() {
        "error" => "Unavailable",
        "warning" => "Limited",
        _ => "Not ready",
    };
    let message = instance.message.trim();
    if message.is_empty() {
        format!("{} — {kind}.", instance.display_name)
    } else {
        format!("{} — {kind}. {message}", instance.display_name)
    }
}

fn show_badge(instance: &Instance, visible: &[&Instance]) -> bool {
    !instance.accent_color.is_empty()
        || visible
            .iter()
            .filter(|other| other.driver == instance.driver)
            .count()
            > 1
}

fn or_null(value: &str) -> Json {
    if value.is_empty() {
        Json::Null
    } else {
        Json::String(value.to_owned())
    }
}

/// `modelPicker.instances`: the rail with each instance's offered models.
/// `started` says whether the thread's session started (models it cannot
/// switch to say why); `current_*` is the thread's own selection.
pub fn picker_instances(
    list: &[Instance],
    prefs: &ModelPrefs,
    selected_instance: &str,
    selected_model: &str,
    started: bool,
    current_instance: &str,
    current_model: &str,
) -> Vec<Json> {
    let visible: Vec<&Instance> = list.iter().filter(|i| i.enabled).collect();
    let mut result = Vec::new();
    for instance in &visible {
        let favorite = |model: &Obj| {
            prefs.favorites.contains(&format!(
                "{}\n{}",
                instance.instance_id,
                text(model, "slug")
            ))
        };
        let mut models: Vec<Obj> =
            model_options(instance, prefs, selected_instance, selected_model)
                .into_iter()
                .filter(|m| offered(instance, m, selected_instance, selected_model))
                .collect();
        models.sort_by_key(|m| !favorite(m));

        let shown: Vec<Json> = models
            .iter()
            .map(|model| {
                let slug = text(model, "slug");
                let disabled_reason = if started {
                    block_reason(
                        list,
                        current_instance,
                        current_model,
                        &instance.instance_id,
                        slug,
                    )
                    .map(|block| {
                        Json::String(format!(
                            "{} Start a new thread to use this model.",
                            block.description
                        ))
                    })
                    .unwrap_or(Json::Null)
                } else {
                    Json::Null
                };
                let name = match text(model, "name") {
                    "" => slug,
                    name => name,
                };
                json!({
                    "slug": slug,
                    "name": name,
                    "shortName": or_null(text(model, "shortName")),
                    "subProvider": or_null(text(model, "subProvider")),
                    "isFavorite": favorite(model),
                    "isCustom": flag(model, "isCustom"),
                    "isNew": text(model, "badge") == "new",
                    "isLegacy": flag(model, "isLegacy"),
                    "isUnavailable": flag(model, "isUnavailable"),
                    "disabledReason": disabled_reason,
                })
            })
            .collect();
        let reason = if instance.ready() {
            Json::Null
        } else {
            Json::String(unavailable_reason(instance))
        };
        result.push(json!({
            "instanceId": instance.instance_id,
            "driverKind": instance.driver,
            "displayName": instance.display_name,
            "accentColor": or_null(&instance.accent_color),
            "iconUrl": or_null(&instance.icon_url),
            "initials": initials_of(&instance.display_name),
            "showBadge": show_badge(instance, &visible),
            "status": instance.status,
            "isAvailable": instance.ready() || !shown.is_empty(),
            "unavailableReason": reason,
            "models": shown,
        }));
    }
    result
}

fn default_choice(descriptor: &Obj) -> Option<Json> {
    array(descriptor, "options")
        .iter()
        .map(as_object)
        .find(|choice| flag(choice, "isDefault"))
        .map(|choice| choice.get("id").cloned().unwrap_or(Json::Null))
}

/// The value a descriptor's choice stands for; none is undefined.
fn choice_value(descriptor: &Obj, raw: &str) -> Option<Json> {
    let choices = array(descriptor, "options");
    let fallback = || {
        descriptor
            .get("currentValue")
            .cloned()
            .or_else(|| default_choice(descriptor))
    };
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return fallback();
    }
    if choices.is_empty() {
        return Some(Json::String(trimmed.to_owned()));
    }
    let known = choices
        .iter()
        .any(|choice| text(as_object(choice), "id") == trimmed);
    let injected = array(descriptor, "promptInjectedValues")
        .iter()
        .any(|v| v.as_str() == Some(trimmed));
    if known && injected {
        return default_choice(descriptor);
    }
    if known {
        Some(Json::String(trimmed.to_owned()))
    } else {
        fallback()
    }
}

/// getProviderOptionCurrentValue.
fn current_value(descriptor: &Obj) -> Option<Json> {
    if text(descriptor, "type") == "boolean" {
        return descriptor.get("currentValue").cloned();
    }
    if !text(descriptor, "currentValue").is_empty() {
        return descriptor.get("currentValue").cloned();
    }
    default_choice(descriptor)
}

fn selections_of(descriptors: &[Json]) -> Vec<Json> {
    descriptors
        .iter()
        .map(as_object)
        .filter_map(|descriptor| {
            let current = current_value(descriptor)?;
            (current.is_string() || current.is_boolean()).then(|| {
                json!({"id": descriptor.get("id").cloned().unwrap_or(Json::Null), "value": current})
            })
        })
        .collect()
}

/// The selected model's option descriptors with their current values.
pub fn descriptors(model: &Obj, selections: &[Json], plan_mode_enabled: bool) -> Vec<Json> {
    let mut result = Vec::new();
    for value in array(object(model, "capabilities"), "optionDescriptors") {
        let mut descriptor = as_object(&value).clone();
        let id = text(&descriptor, "id").to_owned();
        let select = text(&descriptor, "type") == "select";
        if !plan_mode_enabled && select && id == "agent" {
            let choices: Vec<Json> = array(&descriptor, "options")
                .into_iter()
                .filter(|c| text(as_object(c), "id") != "plan")
                .collect();
            if choices.is_empty() {
                continue;
            }
            descriptor.insert("options".into(), Json::Array(choices));
        }
        let mut raw = descriptor.get("currentValue").cloned();
        for selection in selections.iter().map(as_object) {
            if text(selection, "id") == id {
                raw = selection.get("value").cloned();
            }
        }
        if !select {
            if let Some(raw @ Json::Bool(_)) = raw {
                descriptor.insert("currentValue".into(), raw);
            }
        } else {
            let raw = match &raw {
                Some(Json::String(s)) => s.clone(),
                _ => text(&descriptor, "currentValue").to_owned(),
            };
            match choice_value(&descriptor, &raw) {
                None => {
                    descriptor.remove("currentValue");
                }
                Some(current) => {
                    descriptor.insert("currentValue".into(), current);
                }
            }
        }
        result.push(Json::Object(descriptor));
    }
    result
}

/// `composer.options`.
pub fn shell_options(descriptors: &[Json]) -> Vec<Json> {
    descriptors
        .iter()
        .map(as_object)
        .map(|descriptor| {
            let select = text(descriptor, "type") == "select";
            let choices: Vec<Json> = if select {
                array(descriptor, "options")
                    .iter()
                    .map(as_object)
                    .map(|c| json!({"id": text(c, "id"), "label": text(c, "label")}))
                    .collect()
            } else {
                Vec::new()
            };
            json!({
                "id": text(descriptor, "id"),
                "label": text(descriptor, "label"),
                "type": if select { "select" } else { "boolean" },
                "value": descriptor.get("currentValue").cloned().unwrap_or(Json::Null),
                "choices": choices,
            })
        })
        .collect()
}

/// The selections to keep after the user sets option `id`; nothing when the
/// value does not fit the option.
pub fn apply_option(descriptors: &[Json], id: &str, value: &Json) -> Option<Vec<Json>> {
    let mut next = Vec::new();
    let mut applied = false;
    for entry in descriptors {
        let mut descriptor = as_object(entry).clone();
        if text(&descriptor, "id") == id {
            if text(&descriptor, "type") == "select" {
                let choice = value.as_str().unwrap_or("");
                if array(&descriptor, "options")
                    .iter()
                    .any(|known| text(as_object(known), "id") == choice)
                {
                    descriptor.insert("currentValue".into(), Json::String(choice.to_owned()));
                    applied = true;
                }
            } else if let Some(on) = value.as_bool() {
                descriptor.insert("currentValue".into(), Json::Bool(on));
                applied = true;
            }
        }
        next.push(Json::Object(descriptor));
    }
    applied.then(|| selections_of(&next))
}

/// `composer.runtimeModes`: [{value, label, description}].
pub fn runtime_modes(instance: Option<&Instance>) -> Vec<Json> {
    const MODES: [(&str, &str, &str); 4] = [
        (
            "approval-required",
            "Supervised",
            "Ask before commands and file changes.",
        ),
        (
            "auto-accept-edits",
            "Auto-accept edits",
            "Auto-approve edits, ask before other actions.",
        ),
        (
            "auto",
            "Auto",
            "Supported providers approve routine actions; others still ask.",
        ),
        (
            "full-access",
            "Full access",
            "Allow commands and edits without prompts.",
        ),
    ];
    MODES
        .iter()
        .filter(|(value, _, _)| {
            instance.is_none_or(|i| {
                i.runtime_modes.is_empty() || i.runtime_modes.iter().any(|m| m == value)
            })
        })
        .map(|(value, label, description)| {
            json!({"value": value, "label": label, "description": description})
        })
        .collect()
}

/// The last binding whose condition holds and whose shortcut matches wins
/// (resolveShortcutCommand).
#[allow(clippy::too_many_arguments)]
fn command_for(
    bindings: &[Binding],
    mac: bool,
    context: &Context,
    key: &str,
    ctrl: bool,
    meta: bool,
    alt: bool,
    shift: bool,
) -> String {
    for binding in bindings.iter().rev() {
        if !keybindings::evaluate(binding.when.as_ref(), context) {
            continue;
        }
        let s = &binding.shortcut;
        if s.key != key {
            continue;
        }
        let want_meta = s.meta || (s.mod_ && mac);
        let want_ctrl = s.ctrl || (s.mod_ && !mac);
        if meta == want_meta && ctrl == want_ctrl && shift == s.shift && alt == s.alt {
            return binding.command.clone();
        }
    }
    String::new()
}

fn context(pairs: &[(&str, bool)]) -> Context {
    pairs.iter().map(|(k, v)| ((*k).to_owned(), *v)).collect()
}

/// `composer.enterIntents`: {singleLine, multiline}, each held-modifier set
/// ("ctrl+meta+alt+shift" order, "" for none) to what Enter sends.
pub fn enter_intents(
    bindings: &[Binding],
    mac: bool,
    send_shortcut: &str,
    draft: bool,
    running: bool,
) -> Json {
    let context = context(&[
        ("composerFocus", true),
        ("draftThreadRoute", draft),
        ("turnRunning", running),
        ("isDesktop", true),
    ]);
    let table = |multiline: bool| {
        let mut intents = Map::new();
        let needs_modifier =
            send_shortcut == "mod-enter" || (send_shortcut == "mod-enter-multiline" && multiline);
        for mask in 0..16 {
            let (ctrl, meta, alt, shift) =
                (mask & 1 != 0, mask & 2 != 0, mask & 4 != 0, mask & 8 != 0);
            let held: Vec<&str> = [
                (ctrl, "ctrl"),
                (meta, "meta"),
                (alt, "alt"),
                (shift, "shift"),
            ]
            .iter()
            .filter(|(on, _)| *on)
            .map(|(_, name)| *name)
            .collect();
            let command = command_for(bindings, mac, &context, "enter", ctrl, meta, alt, shift);
            let intent = if command == "composer.sendAlternate" && running {
                "alternate"
            } else if command == "composer.sendBackground" && draft {
                "background"
            } else if command.is_empty() && !shift && !alt && (!needs_modifier || ctrl || meta) {
                "foreground"
            } else {
                ""
            };
            if !intent.is_empty() {
                intents.insert(held.join("+"), Json::String(intent.into()));
            }
        }
        Json::Object(intents)
    };
    json!({"singleLine": table(false), "multiline": table(true)})
}

/// One `modelPicker` key: {key, ctrlKey, metaKey, shiftKey, altKey, label},
/// or null when the command has no key with the picker open.
pub fn picker_key(bindings: &[Binding], mac: bool, command: &str) -> Json {
    let context = context(&[("modelPickerOpen", true), ("isDesktop", true)]);
    let mut claimed = HashSet::new();
    for binding in bindings.iter().rev() {
        if !keybindings::evaluate(binding.when.as_ref(), &context) {
            continue;
        }
        let s = &binding.shortcut;
        let meta = s.meta || (s.mod_ && mac);
        let ctrl = s.ctrl || (s.mod_ && !mac);
        if !claimed.insert((s.key.clone(), meta, ctrl, s.shift, s.alt)) {
            continue;
        }
        if binding.command != command {
            continue;
        }
        return json!({
            "key": s.key,
            "ctrlKey": ctrl,
            "metaKey": meta,
            "shiftKey": s.shift,
            "altKey": s.alt,
            "label": keybindings::label(s, mac),
        });
    }
    Json::Null
}

/// The text's length in UTF-16 units, the unit of a QML cursor.
pub fn utf16_len(text: &str) -> usize {
    text.encode_utf16().count()
}

/// The byte offset of a UTF-16 position in `text`, clamped to its end; a
/// position inside a surrogate pair is the pair's start.
pub fn byte_at(text: &str, position: usize) -> usize {
    let mut units = 0;
    for (byte, c) in text.char_indices() {
        if units + c.len_utf16() > position {
            return byte;
        }
        units += c.len_utf16();
    }
    text.len()
}

/// `text` between two UTF-16 positions.
pub fn slice(text: &str, start: usize, end: usize) -> &str {
    let start = byte_at(text, start);
    &text[start..byte_at(text, end).max(start)]
}

/// What the text before the caret asks for: "path" (@), "skill" ($),
/// "slash-command" (/ at a line start) or "pull-request" (#).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Trigger {
    pub kind: String,
    pub query: String,
    /// The span it covers, in UTF-16 units.
    pub start: usize,
    pub end: usize,
}

fn is_space(c: char) -> bool {
    matches!(c, ' ' | '\n' | '\t' | '\r')
}

pub fn trigger(text: &str, cursor: i64) -> Option<Trigger> {
    static COMMAND: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^/(\S*)$").unwrap());
    static PULL_REQUEST: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"^#([\p{L}\p{N}][\p{L}\p{N}_-]*)?$").unwrap());
    let cursor = cursor.clamp(0, utf16_len(text) as i64) as usize;
    let caret = byte_at(text, cursor);
    let before = &text[..caret];
    let line_start = before.rfind('\n').map_or(0, |i| i + 1);
    let line_prefix = &before[line_start..];
    let at = |byte: usize| utf16_len(&text[..byte]);
    if line_prefix.starts_with('/')
        && let Some(found) = COMMAND.captures(line_prefix)
    {
        return Some(Trigger {
            kind: "slash-command".into(),
            query: found[1].to_owned(),
            start: at(line_start),
            end: cursor,
        });
    }
    let token_start = before
        .char_indices()
        .rev()
        .find(|(_, c)| is_space(*c))
        .map_or(0, |(i, c)| i + c.len_utf8());
    let token = &before[token_start..];
    let found = |kind: &str, query: &str| {
        Some(Trigger {
            kind: kind.into(),
            query: query.to_owned(),
            start: at(token_start),
            end: cursor,
        })
    };
    if let Some(m) = PULL_REQUEST.captures(token) {
        return found("pull-request", m.get(1).map_or("", |g| g.as_str()));
    }
    let mut chars = token.chars();
    match chars.next() {
        Some(c) if get_general_category(c) == GeneralCategory::CurrencySymbol => {
            found("skill", chars.as_str())
        }
        Some('@') => found("path", chars.as_str()),
        _ => None,
    }
}

/// A suggestion: `composer.suggestions` shows {id, kind, label,
/// description}; `replacement` is what selecting it puts in the trigger's
/// place.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Suggestion {
    pub id: String,
    pub kind: String,
    pub label: String,
    pub description: String,
    pub replacement: String,
}

struct Ranked {
    item: Suggestion,
    score: i32,
    tie_breaker: String,
}

/// QString::localeAwareCompare.
fn locale_compare(a: &str, b: &str) -> Ordering {
    crate::sidebar_model::locale_compare(a, b)
}

/// insertRankedSearchResult with no limit: by score, then tie-breaker,
/// stable.
fn ranked(mut entries: Vec<Ranked>) -> Vec<Suggestion> {
    entries.sort_by(|a, b| {
        a.score
            .cmp(&b.score)
            .then_with(|| locale_compare(&a.tie_breaker, &b.tie_breaker))
    });
    entries.into_iter().map(|e| e.item).collect()
}

fn best(scores: &[Option<i32>]) -> Option<i32> {
    scores.iter().flatten().copied().min()
}

fn skill_label(skill: &Obj) -> String {
    let named = text(skill, "displayName").trim();
    if !named.is_empty() {
        return named.to_owned();
    }
    text(skill, "name")
        .split(|c: char| c.is_whitespace() || matches!(c, ':' | '_' | '-'))
        .filter(|w| !w.is_empty())
        .map(|word| {
            let mut chars = word.chars();
            chars
                .next()
                .map(|first| first.to_uppercase().chain(chars).collect::<String>())
                .unwrap_or_default()
        })
        .collect::<Vec<_>>()
        .join(" ")
}

const BOUNDARIES: &str = " -_/";

/// How well a skill matches; `query` is already normalised.
fn score_skill(skill: &Obj, query: &str) -> Option<i32> {
    best(&[
        score_query_match(
            &text(skill, "name").to_lowercase(),
            query,
            0,
            2,
            Some(4),
            Some(6),
            Some(100),
            "-_/",
        ),
        score_query_match(
            &skill_label(skill).to_lowercase(),
            query,
            1,
            3,
            Some(5),
            Some(7),
            Some(110),
            BOUNDARIES,
        ),
        score_query_match(
            &text(skill, "shortDescription").to_lowercase(),
            query,
            20,
            22,
            Some(24),
            Some(26),
            None,
            BOUNDARIES,
        ),
        score_query_match(
            &text(skill, "description").to_lowercase(),
            query,
            30,
            32,
            Some(34),
            Some(36),
            None,
            BOUNDARIES,
        ),
        score_query_match(
            &text(skill, "scope").to_lowercase(),
            query,
            40,
            42,
            None,
            Some(44),
            None,
            BOUNDARIES,
        ),
    ])
}

/// Enabled skills a user may start, one per name.
fn invocable_skills(skills: &[Json]) -> Vec<&Obj> {
    let mut seen = HashSet::new();
    skills
        .iter()
        .map(as_object)
        .filter(|skill| {
            flag(skill, "enabled")
                && skill.get("userInvocable") != Some(&Json::Bool(false))
                && seen.insert(text(skill, "name").trim().to_lowercase())
        })
        .collect()
}

fn normalize_query(query: &str, leading: &Regex) -> String {
    let query = query.trim();
    if query.is_empty() {
        return String::new();
    }
    leading.replace(query, "").to_lowercase()
}

/// The / menu for the instance: the composer's own commands, the
/// provider's commands and (when shown there) its skills, ranked for the
/// query.
pub fn slash_items(
    instance: Option<&Instance>,
    trigger: &Trigger,
    plan_mode_enabled: bool,
    show_skills: bool,
    prompt_empty: bool,
) -> Vec<Suggestion> {
    struct Item<'a> {
        suggestion: Suggestion,
        /// 0 the composer's, 1 the provider's commands, 2 skills.
        group: u8,
        name: String,
        skill: Option<&'a Obj>,
    }
    let mut items: Vec<Item> = Vec::new();
    let mut built_in = |command: &str, description: &str| {
        items.push(Item {
            suggestion: Suggestion {
                id: format!("slash:{command}"),
                kind: "slash-command".into(),
                label: format!("/{command}"),
                description: description.into(),
                replacement: String::new(),
            },
            group: 0,
            name: command.into(),
            skill: None,
        });
    };
    built_in("model", "Switch response model for this thread");
    if plan_mode_enabled {
        built_in("plan", "Switch this thread into plan mode");
        built_in("default", "Switch this thread back to normal build mode");
    }
    if let Some(instance) = instance {
        let skills = if show_skills {
            invocable_skills(&instance.skills)
        } else {
            Vec::new()
        };
        let skill_names: HashSet<String> = skills
            .iter()
            .map(|s| text(s, "name").trim().to_lowercase())
            .collect();
        if trigger.start == 0 {
            for command in instance.slash_commands.iter().map(as_object) {
                let name = text(command, "name");
                if skill_names.contains(&name.trim().to_lowercase()) {
                    continue;
                }
                if name == "compact" && !prompt_empty {
                    continue;
                }
                let mut description = text(command, "description");
                if description.is_empty() {
                    description = text(object(command, "input"), "hint");
                }
                if description.is_empty() {
                    description = "Run provider command";
                }
                items.push(Item {
                    suggestion: Suggestion {
                        id: format!("provider-slash-command:{}:{name}", instance.driver),
                        kind: "provider-slash-command".into(),
                        label: format!("/{name}"),
                        description: description.into(),
                        replacement: format!("/{name} "),
                    },
                    group: 1,
                    name: name.into(),
                    skill: None,
                });
            }
        }
        for skill in skills {
            let name = text(skill, "name");
            items.push(Item {
                suggestion: Suggestion {
                    id: format!("skill:{}:{name}", instance.driver),
                    kind: "skill".into(),
                    label: format!("/skill:{name}"),
                    description: skill_description(skill, ""),
                    replacement: format!("${name} "),
                },
                group: 2,
                name: name.into(),
                skill: Some(skill),
            });
        }
    }

    static SLASHES: LazyLock<Regex> = LazyLock::new(|| Regex::new("^/+").unwrap());
    let query = normalize_query(&trigger.query, &SLASHES);
    if query.is_empty() {
        return items.into_iter().map(|i| i.suggestion).collect();
    }
    let provider = instance.map(|i| i.driver.as_str()).unwrap_or("");
    let mut scored = Vec::new();
    for item in items {
        let score = if let Some(skill) = item.skill {
            if query == "skill" {
                Some(0)
            } else {
                let skill_query = query.strip_prefix("skill:").unwrap_or(&query);
                let score = if skill_query.is_empty() {
                    Some(0)
                } else {
                    score_skill(skill, skill_query)
                };
                score.or_else(|| "skill".starts_with(query.as_str()).then_some(i32::MAX))
            }
        } else {
            best(&[
                score_query_match(
                    &item.name.to_lowercase(),
                    &query,
                    0,
                    2,
                    Some(4),
                    Some(6),
                    Some(100),
                    "-_/",
                ),
                score_query_match(
                    &item.suggestion.description.to_lowercase(),
                    &query,
                    20,
                    22,
                    Some(24),
                    Some(26),
                    None,
                    BOUNDARIES,
                ),
            ])
        };
        let Some(score) = score else { continue };
        let tie_breaker = match item.group {
            0 => format!("0\0{}", item.name),
            1 => format!("1\0{}\0{provider}", item.name),
            _ => format!("2\0{}\0{provider}", item.name),
        };
        scored.push(Ranked {
            item: item.suggestion,
            score,
            tie_breaker,
        });
    }
    ranked(scored)
}

/// A skill's description: its short one, its long one, or its scope's.
fn skill_description(skill: &Obj, otherwise: &str) -> String {
    let mut description = text(skill, "shortDescription");
    if description.is_empty() {
        description = text(skill, "description");
    }
    if !description.is_empty() {
        return description.to_owned();
    }
    match text(skill, "scope") {
        "" => otherwise.to_owned(),
        scope => format!("{scope} skill"),
    }
}

/// The $ menu: the instance's skills ranked for the query.
pub fn skill_items(instance: Option<&Instance>, trigger: &Trigger) -> Vec<Suggestion> {
    let Some(instance) = instance else {
        return Vec::new();
    };
    let to_item = |skill: &Obj| {
        let name = text(skill, "name");
        Suggestion {
            id: format!("skill:{}:{name}", instance.driver),
            kind: "skill".into(),
            label: skill_label(skill),
            description: skill_description(skill, "Run provider skill"),
            replacement: format!("${name} "),
        }
    };
    static CURRENCY: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\p{Sc}+").unwrap());
    let query = normalize_query(&trigger.query, &CURRENCY);
    let skills = invocable_skills(&instance.skills);
    if query.is_empty() {
        return skills.into_iter().map(to_item).collect();
    }
    ranked(
        skills
            .into_iter()
            .filter_map(|skill| {
                Some(Ranked {
                    score: score_skill(skill, &query)?,
                    tie_breaker: format!(
                        "{}\0{}",
                        skill_label(skill).to_lowercase(),
                        text(skill, "name")
                    ),
                    item: to_item(skill),
                })
            })
            .collect(),
    )
}

/// The @ menu: the entries of a workspace search (path, is a directory),
/// as file links.
pub fn path_items(entries: &[(String, bool)]) -> Vec<Suggestion> {
    entries
        .iter()
        .map(|(path, directory)| {
            let kind = if *directory { "directory" } else { "file" };
            let (description, label) = match path.rfind('/') {
                Some(slash) => (&path[..slash], &path[slash + 1..]),
                None => ("", path.as_str()),
            };
            Suggestion {
                id: format!("path:{kind}:{path}"),
                kind: "path".into(),
                label: label.into(),
                description: description.into(),
                replacement: path_link(path),
            }
        })
        .collect()
}

/// A path as the prompt names it (serializeComposerFileLink): `[name](path)`
/// with the path URI-encoded, and the trailing space the @ menu adds.
pub fn path_link(path: &str) -> String {
    let name = path.split('/').rfind(|s| !s.is_empty()).unwrap_or("");
    let label = if name.is_empty() { path } else { name };
    let label = label
        .replace('\\', "\\\\")
        .replace('[', "\\[")
        .replace(']', "\\]");
    // encodeURI, with ( ) # ? and \ escaped too.
    let mut destination = String::new();
    for byte in path.bytes() {
        if byte.is_ascii_alphanumeric() || b"/:@!$&'*+,;=-._~".contains(&byte) {
            destination.push(byte as char);
        } else {
            destination.push_str(&format!("%{byte:02X}"));
        }
    }
    format!("[{label}]({destination}) ")
}

/// The text the empty menu shows for the trigger.
pub fn empty_text(kind: &str) -> &'static str {
    match kind {
        "skill" => "No skills found. Try / to browse provider commands.",
        "path" => "No matching files or folders.",
        "slash-command" => "No matching command.",
        _ => "",
    }
}

fn find_units(haystack: &[u16], needle: &[u16]) -> Option<usize> {
    if needle.len() > haystack.len() {
        return None;
    }
    (0..=haystack.len() - needle.len()).find(|&i| haystack[i..].starts_with(needle))
}

/// How well a value matches a query: lower is better, none is no match.
/// Indices count UTF-16 units, as the web client's do.
#[allow(clippy::too_many_arguments)]
pub fn score_query_match(
    value: &str,
    query: &str,
    exact_base: i32,
    prefix_base: i32,
    boundary_base: Option<i32>,
    includes_base: Option<i32>,
    fuzzy_base: Option<i32>,
    boundary_markers: &str,
) -> Option<i32> {
    if value.is_empty() || query.is_empty() {
        return None;
    }
    if value == query {
        return Some(exact_base);
    }
    let v: Vec<u16> = value.encode_utf16().collect();
    let q: Vec<u16> = query.encode_utf16().collect();
    let length_penalty = v.len().saturating_sub(q.len()).min(64) as i32;
    if v.starts_with(&q) {
        return Some(prefix_base + length_penalty);
    }
    if let Some(base) = boundary_base {
        let best_index = boundary_markers
            .encode_utf16()
            .filter_map(|marker| {
                let mut needle = vec![marker];
                needle.extend_from_slice(&q);
                find_units(&v, &needle).map(|i| i + 1)
            })
            .min();
        if let Some(index) = best_index {
            return Some(base + index as i32 * 2 + length_penalty);
        }
    }
    if let Some(base) = includes_base
        && let Some(index) = find_units(&v, &q)
    {
        return Some(base + index as i32 * 2 + length_penalty);
    }
    if let Some(base) = fuzzy_base {
        let mut query_index = 0;
        let mut first: Option<usize> = None;
        let mut previous: Option<usize> = None;
        let mut gaps = 0;
        for (i, unit) in v.iter().enumerate() {
            if *unit != q[query_index] {
                continue;
            }
            let start = *first.get_or_insert(i);
            if let Some(previous) = previous {
                gaps += (i - previous - 1) as i32;
            }
            previous = Some(i);
            query_index += 1;
            if query_index == q.len() {
                let span = (i - start + 1 - q.len()) as i32;
                let length = (v.len() - q.len()).min(64) as i32;
                return Some(base + start as i32 * 2 + gaps * 3 + span + length);
            }
        }
    }
    None
}

/// What waits behind the running turn, from the thread's runs and the
/// messages the timeline holds, each in the order it runs: the user's
/// queued follow-ups (`runId`, `text`), and what the MC queued for the agent
/// itself, a delegated task's result or the provider's wake-up (`runId`,
/// `summary`, `outcome`), which is not the user's to edit, steer with or
/// remove. A run whose message has not arrived yet is in neither: which it
/// is, and what it says, comes with the message. `held` is the MC keeping
/// the queue for the user (after a restart or a usage limit) until it is
/// resumed, whether or not every run is listed yet.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Queued {
    pub queue: Vec<Json>,
    pub waiting: Vec<Json>,
    pub held: bool,
}

impl Queued {
    /// Held with something listed: the card shows and the resume is
    /// offered. Held with nothing listed shows no card, so it offers no
    /// resume either.
    pub fn shown_held(&self) -> bool {
        self.held && (!self.queue.is_empty() || !self.waiting.is_empty())
    }
}

fn number(object: &Obj, field: &str, otherwise: f64) -> f64 {
    object
        .get(field)
        .and_then(Json::as_f64)
        .unwrap_or(otherwise)
}

pub fn queued<'a>(
    runs: impl IntoIterator<Item = &'a Obj>,
    message: impl Fn(&str) -> Option<&'a Obj>,
) -> Queued {
    let mut waiting: Vec<&Obj> = runs
        .into_iter()
        .filter(|run| text(run, "status") == "queued")
        .collect();
    // By queue position, which the MC keeps whole; a run's id settles a tie,
    // so the order is the same whatever order the runs came in.
    let position = |run: &Obj| number(run, "queuePosition", number(run, "ordinal", 0.0));
    waiting.sort_by(|a, b| {
        position(a)
            .partial_cmp(&position(b))
            .unwrap_or(Ordering::Equal)
            .then_with(|| text(a, "id").cmp(text(b, "id")))
    });
    let mut queued = Queued::default();
    for run in waiting {
        // Held is the queue's, listed run or not; the card shows it only
        // with a run to list.
        queued.held = queued.held || flag(run, "queueHeld");
        let run_id = text(run, "id");
        let Some(message) = message(text(run, "userMessageId")) else {
            continue;
        };
        if message.get("notification").is_some_and(Json::is_object)
            || message
                .get("delegatedCompletion")
                .is_some_and(Json::is_object)
            || flag(message, "providerWake")
        {
            let notice = summary::notice_of(message);
            let summary = notice
                .as_ref()
                .map(|n| n.summary.as_str())
                .filter(|s| !s.is_empty())
                .unwrap_or("Notification");
            queued.waiting.push(json!({
                "runId": run_id,
                "summary": summary,
                "outcome": notice.as_ref().map(|n| n.outcome.as_str()).unwrap_or(""),
            }));
            continue;
        }
        queued
            .queue
            .push(json!({"runId": run_id, "text": text(message, "text")}));
    }
    queued
}

#[cfg(test)]
mod tests;
