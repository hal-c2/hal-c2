//! The Providers section's instances: adding one with the wizard, and
//! editing, resetting and deleting one where the MC reads it, its
//! `providerInstances` entry ([`crate::provider::instances`]).
//!
//! Actions (each on the shown environment): `providerSettings.wizardOpen`,
//! `.wizardClose`, `.wizardDriver {driver}`, `.wizardLabel {label}`,
//! `.wizardAccent {color}`, `.wizardInstanceId {instanceId}`, `.wizardField
//! {key, value}`, `.wizardStep {step, label?, instanceId?}` (moving on past
//! Identity needs a valid id; going back always works), `.wizardSubmit
//! {label?, instanceId?}`; `.rename {instanceId, name}`, `.accent
//! {instanceId, color}`, `.field {instanceId, key, value}`, `.secret
//! {instanceId, name, value}` (a driver's own variable, such as Cursor's API
//! key; empty removes it), `.addVariable {instanceId}`, `.variable
//! {instanceId, index, name | value | sensitive}`, `.removeVariable
//! {instanceId, index}`, `.delete {instanceId}` (an added instance), `.reset
//! {instanceId}` (a built-in's own slot); `.addModel {instanceId, slug}`,
//! `.editModel {instanceId, slug}` (opens its draft; empty closes it),
//! `.modelDraft {instanceId, name | options | copyFrom (a built-in model's
//! slug)}`, `.saveModel {instanceId, slug}` (the draft) and `.removeModel
//! {instanceId, slug}`: custom models ([`crate::provider::custom_models`]).
//!
//! Each listed provider also carries: editable (its settings arrived),
//! custom (added, so deletable), resettable, label (its own name, "" for
//! none), placeholder, accentColor, fields [{key, label, description,
//! placeholder, control: text | password | select, options [{value, label}],
//! value}], secrets [{name, label, description, placeholder, stored}],
//! variables [{name, value, sensitive, redacted, invalid, placeholder}],
//! pending (added but not yet reported by the environment), takesModels,
//! customModels [{slug, name, options}], modelPresets and copyFrom [{slug,
//! name, options}] (options to start from), modelDraft (null | {slug, name,
//! options}, the model being edited) and modelError.
//!
//! `wizard`: {step, steps, drivers [{id, label, badge}], driver,
//! driverLabel, label, accentColor, instanceId, instanceIdError ("" until
//! moving on was tried), fields, saving, registry (see [`super::registry`])}.

use std::collections::{BTreeSet, HashSet};

use ljos::prelude::Engine;
use serde_json::{Map, json};

use super::{
    NULL, ProviderSettings, REGISTRY, Saved, Wizard, array_at, at, empty, has, input_bool,
    input_int, input_string, object_at, str_at, toast,
};
use crate::json::Json;
use crate::mc::McError;
use crate::provider::drivers::{self, Driver, Field};
use crate::provider::{custom_models, instances};

const STEPS: [&str; 3] = ["Provider", "Identity", "Config"];
/// An agent chosen from the registry is set up by it; it signs in from its
/// card.
const REGISTRY_STEPS: [&str; 2] = ["Provider", "Identity"];

fn steps(driver: &str, manual: bool) -> &'static [&'static str] {
    if driver == REGISTRY && !manual {
        &REGISTRY_STEPS
    } else {
        &STEPS
    }
}

/// A config value as text.
fn config_text(value: &Json) -> String {
    match value {
        Json::String(s) => s.clone(),
        Json::Number(n) => n.as_f64().map(super::number_text).unwrap_or_default(),
        Json::Bool(b) => b.to_string(),
        _ => String::new(),
    }
}

/// A driver's settings with `config`'s values.
fn fields(driver: &Driver, config: &Map<String, Json>) -> Vec<Json> {
    driver
        .fields
        .iter()
        .map(|field| {
            let options: Vec<Json> = field
                .options
                .iter()
                .map(|(value, label)| json!({"value": value, "label": label}))
                .collect();
            let mut value = config_text(config.get(field.key).unwrap_or(&NULL));
            if value.is_empty()
                && let Some((first, _)) = field.options.first()
            {
                value = (*first).to_owned();
            }
            json!({
                "key": field.key,
                "label": field.label,
                "description": field.description,
                "placeholder": field.placeholder,
                "control": field.control,
                "options": options,
                "value": value,
            })
        })
        .collect()
}

fn field(driver: &str, key: &str) -> Option<&'static Field> {
    drivers::find(driver)?.fields.iter().find(|f| f.key == key)
}

/// The variables a driver asks for by name, which the generic rows leave out.
fn dedicated(driver: &str) -> HashSet<&'static str> {
    drivers::find(driver)
        .map(|d| d.variables.iter().map(|v| v.name).collect())
        .unwrap_or_default()
}

/// A row just added and left alone, which is not saved.
fn blank(row: &Json) -> bool {
    str_at(row, "name").trim().is_empty()
        && str_at(row, "value").is_empty()
        && super::bool_at(row, "sensitive")
        && row.get("valueRedacted").is_none()
}

fn invalid(row: &Json) -> bool {
    !blank(row) && !instances::valid_variable_name(str_at(row, "name").trim())
}

fn with_environment(instance: Json, environment: Vec<Json>) -> Json {
    let mut instance = instance.as_object().cloned().unwrap_or_default();
    if environment.is_empty() {
        instance.remove("environment");
    } else {
        instance.insert("environment".into(), Json::Array(environment));
    }
    Json::Object(instance)
}

fn with_text(instance: Json, key: &str, value: &str) -> Json {
    let mut instance = instance.as_object().cloned().unwrap_or_default();
    if value.is_empty() {
        instance.remove(key);
    } else {
        instance.insert(key.into(), Json::String(value.into()));
    }
    Json::Object(instance)
}

/// The rows of an instance's environment the generic editor shows.
fn generic_rows(instance: &Json, driver: &str) -> Vec<Json> {
    let own = dedicated(driver);
    array_at(instance, "environment")
        .iter()
        .filter(|v| !own.contains(str_at(v, "name")))
        .cloned()
        .collect()
}

/// A custom model entry's slug: a bare string's, or an object's.
fn entry_slug(value: &Json) -> &str {
    match value {
        Json::String(slug) => slug.trim(),
        other => str_at(other, "slug").trim(),
    }
}

impl ProviderSettings {
    /// An instance's driver: as the environment lists it, else as it is
    /// configured, else a built-in's own slot.
    pub(super) fn driver_of(&self, instance_id: &str) -> String {
        if instance_id.is_empty() {
            return String::new();
        }
        let listed = str_at(&self.provider(instance_id), "driver").to_owned();
        if !listed.is_empty() {
            return listed;
        }
        if let Some(settings) = self.shown_settings() {
            let configured = str_at(
                at(at(&settings, "providerInstances"), instance_id),
                "driver",
            );
            if !configured.is_empty() {
                return configured.to_owned();
            }
        }
        match drivers::find(instance_id) {
            Some(driver) if driver.built_in => instance_id.to_owned(),
            _ => String::new(),
        }
    }

    /// The ids a new instance may not take.
    pub(super) fn taken(&self) -> BTreeSet<String> {
        instances::taken(
            &self.shown_settings().unwrap_or_else(|| json!({})),
            self.providers.as_deref().unwrap_or_default(),
        )
    }

    fn edit_instance(
        &mut self,
        engine: &Engine,
        instance_id: &str,
        change: impl Fn(Json) -> Json + 'static,
        done: Option<Saved>,
    ) {
        let driver = self.driver_of(instance_id);
        if driver.is_empty() {
            return;
        }
        let id = instance_id.to_owned();
        self.save(
            engine,
            move |settings, _| {
                let instance = change(instances::of(&settings, &id, &driver));
                instances::with(settings, &id, instance)
            },
            done,
            "Could not update provider instance",
        );
    }

    /// The rows as edited; they are saved once each is complete.
    fn set_variables(&mut self, engine: &Engine, instance_id: &str, rows: Vec<Json>) {
        self.variables.insert(instance_id.to_owned(), rows.clone());
        self.publish(engine);
        let mut environment = Vec::new();
        for row in &rows {
            if invalid(row) {
                return;
            }
            if blank(row) {
                continue;
            }
            let mut variable = json!({
                "name": str_at(row, "name").trim(),
                "value": str_at(row, "value"),
                "sensitive": super::bool_at(row, "sensitive"),
            });
            if super::bool_at(row, "valueRedacted") {
                variable["valueRedacted"] = Json::Bool(true);
            }
            environment.push(variable);
        }
        let own: HashSet<String> = dedicated(&self.driver_of(instance_id))
            .into_iter()
            .map(String::from)
            .collect();
        let id = instance_id.to_owned();
        self.edit_instance(
            engine,
            instance_id,
            move |instance| {
                let mut next: Vec<Json> = array_at(&instance, "environment")
                    .iter()
                    .filter(|v| own.contains(str_at(v, "name")))
                    .cloned()
                    .collect();
                next.extend(environment.iter().cloned());
                with_environment(instance, next)
            },
            Some(Box::new(
                move |c: &mut ProviderSettings, engine: &Engine, saved| {
                    // Saved rows show as the environment keeps them (a secret
                    // redacted); a blank one stays until it is filled in or removed.
                    let settled = !rows.iter().any(blank);
                    if saved && settled && c.variables.get(&id) == Some(&rows) {
                        c.variables.remove(&id);
                    }
                    c.publish(engine);
                },
            )),
        );
    }

    pub(super) fn handle_instance(
        &mut self,
        engine: &Engine,
        action: &str,
        payload: &Json,
    ) -> bool {
        if action.starts_with("providerSettings.wizard") {
            if !self.handle_wizard(engine, action, payload) {
                return false;
            }
            self.publish(engine);
            return true;
        }
        let instance_id = str_at(payload, "instanceId").to_owned();
        let driver = self.driver_of(&instance_id);
        match action {
            "providerSettings.rename" => {
                let name = input_string(payload, "name").trim().to_owned();
                self.edit_instance(
                    engine,
                    &instance_id,
                    move |instance| with_text(instance, "displayName", &name),
                    None,
                );
            }
            "providerSettings.accent" => {
                let color = instances::accent(&input_string(payload, "color"));
                self.edit_instance(
                    engine,
                    &instance_id,
                    move |instance| with_text(instance, "accentColor", &color),
                    None,
                );
            }
            "providerSettings.field" => {
                let Some(found) = field(&driver, &input_string(payload, "key")) else {
                    return true;
                };
                let key = found.key;
                let keep_empty = found.keep_empty;
                let value = input_string(payload, "value");
                self.edit_instance(
                    engine,
                    &instance_id,
                    move |instance| {
                        let mut instance =
                            instances::with_config(instance, key, &Json::String(value.clone()));
                        if keep_empty && value.trim().is_empty() {
                            let mut config = object_at(&instance, "config");
                            config.insert(key.into(), Json::String(String::new()));
                            instance["config"] = Json::Object(config);
                        }
                        instance
                    },
                    None,
                );
            }
            "providerSettings.secret" => {
                // nextProviderEnvironmentWithFieldValue: the trimmed value, or none.
                let name = input_string(payload, "name");
                let Some(variable) = drivers::find(&driver)
                    .and_then(|d| d.variables.iter().rfind(|v| v.name == name))
                else {
                    return true;
                };
                let value = input_string(payload, "value").trim().to_owned();
                let sensitive = variable.sensitive;
                self.edit_instance(
                    engine,
                    &instance_id,
                    move |instance| {
                        let mut next: Vec<Json> = array_at(&instance, "environment")
                            .iter()
                            .filter(|v| at(v, "name").as_str() != Some(name.as_str()))
                            .cloned()
                            .collect();
                        if !value.is_empty() {
                            next.push(
                                json!({"name": name, "value": value, "sensitive": sensitive}),
                            );
                        }
                        with_environment(instance, next)
                    },
                    None,
                );
            }
            "providerSettings.addVariable"
            | "providerSettings.variable"
            | "providerSettings.removeVariable" => {
                if driver.is_empty() {
                    return true;
                }
                let mut rows = match self.variables.get(&instance_id) {
                    Some(rows) => rows.clone(),
                    None => {
                        let settings = self.shown_settings().unwrap_or_else(|| json!({}));
                        generic_rows(&instances::of(&settings, &instance_id, &driver), &driver)
                    }
                };
                let index = if has(payload, "index") {
                    input_int(payload, "index")
                } else {
                    -1
                };
                if action == "providerSettings.addVariable" {
                    rows.push(json!({"name": "", "value": "", "sensitive": true}));
                    self.variables.insert(instance_id, rows);
                    self.publish(engine);
                    return true;
                }
                if index < 0 || index as usize >= rows.len() {
                    return true;
                }
                let index = index as usize;
                if action == "providerSettings.removeVariable" {
                    rows.remove(index);
                } else {
                    let mut row = rows[index].as_object().cloned().unwrap_or_default();
                    if has(payload, "name") {
                        let name = input_string(payload, "name").trim().to_owned();
                        // The stored secret belongs to the old name; a renamed
                        // row asks for its value again.
                        let old = row.get("name").and_then(Json::as_str).unwrap_or_default();
                        if name != old
                            && row.get("valueRedacted").and_then(Json::as_bool) == Some(true)
                        {
                            row.insert("valueRedacted".into(), Json::Bool(false));
                        }
                        row.insert("name".into(), Json::String(name));
                    }
                    if has(payload, "value") {
                        row.insert("value".into(), Json::String(input_string(payload, "value")));
                        row.insert("valueRedacted".into(), Json::Bool(false));
                    }
                    if has(payload, "sensitive") {
                        let sensitive = input_bool(payload, "sensitive");
                        row.insert("sensitive".into(), Json::Bool(sensitive));
                        // A secret made plain text needs its value again.
                        if !sensitive && row.contains_key("valueRedacted") {
                            row.insert("valueRedacted".into(), Json::Bool(false));
                        }
                    }
                    rows[index] = Json::Object(row);
                }
                self.set_variables(engine, &instance_id, rows);
            }
            "providerSettings.delete" => self.delete_instance(engine, &instance_id, &driver),
            "providerSettings.addModel"
            | "providerSettings.saveModel"
            | "providerSettings.removeModel" => {
                self.change_model(engine, action, &instance_id, &driver, payload);
            }
            "providerSettings.editModel" => {
                let slug = input_string(payload, "slug");
                self.model_error.remove(&instance_id);
                self.model_draft.remove(&instance_id);
                let saved = self.saved_models(&instance_id, &driver);
                for model in custom_models::read(&saved).as_array().into_iter().flatten() {
                    if str_at(model, "slug") == slug {
                        self.model_draft.insert(instance_id.clone(), model.clone());
                    }
                }
                self.publish(engine);
            }
            "providerSettings.modelDraft" => {
                let models = self.provider(&instance_id);
                let Some(Json::Object(draft)) = self.model_draft.get_mut(&instance_id) else {
                    return true;
                };
                if has(payload, "name") {
                    draft.insert("name".into(), Json::String(input_string(payload, "name")));
                }
                if has(payload, "options") {
                    let options = at(payload, "options")
                        .as_array()
                        .cloned()
                        .unwrap_or_default();
                    draft.insert("options".into(), Json::Array(options));
                }
                let source = input_string(payload, "copyFrom");
                let copyable = custom_models::copyable(array_at(&models, "models"), &driver);
                for model in copyable.as_array().into_iter().flatten() {
                    if !source.is_empty() && str_at(model, "slug") == source {
                        draft.insert("options".into(), at(model, "options").clone());
                    }
                }
                self.model_error.remove(&instance_id);
                self.publish(engine);
            }
            "providerSettings.reset" => {
                let built_in = drivers::find(&driver).is_some_and(|d| d.built_in);
                if !built_in || instance_id != driver {
                    return true;
                }
                self.variables.remove(&instance_id);
                self.save(
                    engine,
                    move |settings, _| {
                        let settings = instances::with(settings, &driver, json!({}));
                        let mut providers = object_at(&settings, "providers");
                        providers.remove(&driver);
                        let mut root = settings.as_object().cloned().unwrap_or_default();
                        root.insert("providers".into(), Json::Object(providers));
                        Json::Object(root)
                    },
                    None,
                    "Could not reset provider instance",
                );
            }
            _ => return false,
        }
        true
    }

    /// A wizard action; false for one this does not know.
    fn handle_wizard(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if action == "providerSettings.wizardOpen" {
            if self.followed.is_empty() {
                return true;
            }
            self.wizards += 1;
            self.wizard = Some(Wizard::new(self.wizards));
            // An empty query lists the registry's compatible agents.
            self.search_registry(engine, String::new());
            return true;
        }
        let Some(wizard) = self.wizard.as_mut().filter(|w| !w.saving) else {
            return true;
        };
        match action {
            "providerSettings.wizardClose" => self.wizard = None,
            "providerSettings.wizardDriver" => {
                let driver = input_string(payload, "driver");
                if drivers::find(&driver).is_some() && driver != REGISTRY {
                    wizard.driver = driver;
                    wizard.manual = false;
                    wizard.attempted = false;
                }
            }
            "providerSettings.wizardLabel" => {
                let driver = wizard.driver.clone();
                wizard
                    .identity
                    .entry(driver)
                    .or_default()
                    .insert("label".into(), Json::String(input_string(payload, "label")));
            }
            "providerSettings.wizardAccent" => {
                let driver = wizard.driver.clone();
                wizard.identity.entry(driver).or_default().insert(
                    "accentColor".into(),
                    Json::String(input_string(payload, "color")),
                );
            }
            "providerSettings.wizardInstanceId" => {
                let driver = wizard.driver.clone();
                wizard.identity.entry(driver).or_default().insert(
                    "instanceId".into(),
                    Json::String(input_string(payload, "instanceId").trim().to_owned()),
                );
            }
            "providerSettings.wizardField" => {
                let key = input_string(payload, "key");
                let Some(found) = field(&wizard.driver, &key) else {
                    return true;
                };
                let current = wizard
                    .config
                    .get(&wizard.driver)
                    .cloned()
                    .unwrap_or_default();
                let config = instances::with_config(
                    json!({"config": current}),
                    found.key,
                    &Json::String(input_string(payload, "value")),
                );
                let config = object_at(&config, "config");
                wizard.config.insert(wizard.driver.clone(), config);
            }
            "providerSettings.wizardStep" | "providerSettings.wizardSubmit" => {
                self.wizard_move(engine, action == "providerSettings.wizardSubmit", payload);
            }
            _ => return false,
        }
        true
    }

    fn wizard_move(&mut self, engine: &Engine, submit: bool, payload: &Json) {
        let ids = self.taken();
        // resolveAcpRegistryWizardNavigation: moving on from Provider needs an agent.
        let chosen = self.registry_selection_error().is_empty();
        let Some(wizard) = self.wizard.as_mut() else {
            return;
        };
        let driver = wizard.driver.clone();
        // The wizard keeps a label or id being typed to itself and hands it over here.
        let identity = wizard.identity.entry(driver.clone()).or_default();
        if has(payload, "label") {
            identity.insert("label".into(), Json::String(input_string(payload, "label")));
        }
        if has(payload, "instanceId") {
            identity.insert(
                "instanceId".into(),
                Json::String(input_string(payload, "instanceId").trim().to_owned()),
            );
        }
        let identity = Json::Object(identity.clone());
        let driver_label = drivers::find(&driver).map(|d| d.label).unwrap_or_default();
        let label = match identity.get("label") {
            Some(label) => label.as_str().unwrap_or_default().to_owned(),
            None => driver_label.to_owned(),
        };
        let id = match identity.get("instanceId") {
            Some(id) => id.as_str().unwrap_or_default().to_owned(),
            None => drivers::derive_id(&driver, &label, &ids),
        };
        let valid = drivers::validate_id(&id, &ids).is_empty();
        if !chosen && (submit || input_int(payload, "step") > 0) {
            wizard.attempted = true;
            wizard.step = 0;
            return;
        }
        if !submit {
            // resolveWizardNavigation: moving on past Identity needs a valid id.
            let last = steps(&driver, wizard.manual).len() as i64 - 1;
            let target = input_int(payload, "step").clamp(0, last);
            if wizard.step <= 1 && target > 1 && !valid {
                wizard.attempted = true;
                wizard.step = 1;
            } else {
                wizard.step = target;
            }
            return;
        }
        wizard.attempted = true;
        if !valid {
            wizard.step = 1;
            return;
        }
        let mut instance = json!({"driver": driver, "enabled": true});
        if !label.trim().is_empty() {
            instance["displayName"] = Json::String(label.trim().to_owned());
        }
        let accent = instances::accent(str_at(&identity, "accentColor"));
        if !accent.is_empty() {
            instance["accentColor"] = Json::String(accent);
        }
        if let Some(config) = wizard.config.get(&driver).filter(|c| !c.is_empty()) {
            instance["config"] = Json::Object(config.clone());
        }
        wizard.saving = true;
        let wizard_id = wizard.id;
        let saved_id = id.clone();
        self.save(
            engine,
            move |settings, _| instances::with(settings, &saved_id, instance.clone()),
            Some(Box::new(
                move |c: &mut ProviderSettings, engine: &Engine, saved| {
                    let Some(wizard) = c.wizard.as_mut().filter(|w| w.id == wizard_id) else {
                        return;
                    };
                    if saved {
                        c.wizard = None;
                        toast(
                            engine,
                            "success",
                            "Provider instance added",
                            &format!("{driver_label} instance '{id}' was added."),
                        );
                    } else {
                        wizard.saving = false;
                    }
                    c.publish(engine);
                },
            )),
            "Could not add provider instance",
        );
    }

    fn delete_instance(&mut self, engine: &Engine, instance_id: &str, driver: &str) {
        let built_in = drivers::find(driver).is_some_and(|d| d.built_in);
        if driver.is_empty() || (built_in && instance_id == driver) {
            return;
        }
        let agent_id = self
            .shown_settings()
            .map(|settings| {
                let instance = instances::of(&settings, instance_id, driver);
                str_at(at(&instance, "config"), "agentId").trim().to_owned()
            })
            .unwrap_or_default();
        let environment = self.followed.clone();
        let registry = driver == REGISTRY;
        self.variables.remove(instance_id);
        let id = instance_id.to_owned();
        self.save(
            engine,
            move |settings, _| instances::with(settings, &id, json!({})),
            Some(Box::new(
                move |c: &mut ProviderSettings, _engine: &Engine, saved| {
                    if !saved || !registry || agent_id.is_empty() {
                        return;
                    }
                    // The environment decides from its own settings whether another
                    // instance still runs the agent.
                    c.mc.call(
                        &environment,
                        "server.uninstallAcpRegistryManagedBinary",
                        json!({"agentId": agent_id}),
                        Box::new(|engine, result: Result<Json, McError>| {
                            if let Err(error) = result {
                                toast(
                                    engine,
                                    "warning",
                                    "Provider deleted, but managed files remain",
                                    &super::error_text(&error, "Managed binary cleanup failed."),
                                );
                            }
                        }),
                    );
                },
            )),
            "Could not delete provider instance",
        );
    }

    /// The instance's saved `config.customModels`.
    fn saved_models(&self, instance_id: &str, driver: &str) -> Json {
        let settings = self.shown_settings().unwrap_or_else(|| json!({}));
        at(
            at(&instances::of(&settings, instance_id, driver), "config"),
            "customModels",
        )
        .clone()
    }

    fn change_model(
        &mut self,
        engine: &Engine,
        action: &str,
        instance_id: &str,
        driver: &str,
        payload: &Json,
    ) {
        if driver.is_empty() {
            return;
        }
        let slug = input_string(payload, "slug").trim().to_owned();
        let saved = self.saved_models(instance_id, driver);
        let (refused, stored) = match action {
            "providerSettings.addModel" => (
                custom_models::refusal(
                    &slug,
                    array_at(&self.provider(instance_id), "models"),
                    &saved,
                ),
                Json::String(slug.clone()),
            ),
            "providerSettings.saveModel" => {
                let draft = self.model_draft.get(instance_id).unwrap_or(&NULL);
                if str_at(draft, "slug") != slug {
                    return;
                }
                let options = array_at(draft, "options");
                (
                    custom_models::problem(options),
                    custom_models::setting(&slug, str_at(draft, "name"), options),
                )
            }
            _ => (String::new(), Json::Null),
        };
        if !refused.is_empty() {
            self.model_error.insert(instance_id.to_owned(), refused);
            self.publish(engine);
            return;
        }
        self.model_error.remove(instance_id);
        let add = action == "providerSettings.addModel";
        let replace = action == "providerSettings.saveModel";
        if !add {
            self.model_draft.remove(instance_id);
        }
        self.publish(engine);
        self.edit_instance(
            engine,
            instance_id,
            move |instance| {
                let mut next = Vec::new();
                for value in array_at(at(&instance, "config"), "customModels") {
                    if entry_slug(value) != slug {
                        next.push(value.clone());
                    } else if replace {
                        next.push(stored.clone());
                    }
                }
                if add {
                    next.push(stored.clone());
                }
                // An emptied list stays stored: it overrides the driver's own
                // `providers` entry.
                let mut config = object_at(&instance, "config");
                config.insert("customModels".into(), Json::Array(next));
                let mut instance = instance.as_object().cloned().unwrap_or_default();
                instance.insert("config".into(), Json::Object(config));
                Json::Object(instance)
            },
            None,
        );
    }

    /// What an entry shows of the instance's configuration.
    pub(super) fn configuration(
        &self,
        result: &mut Map<String, Json>,
        instance_id: &str,
        driver: &str,
    ) {
        let found = drivers::find(driver);
        let custom = !(found.is_some_and(|d| d.built_in) && instance_id == driver);
        let settings = self.shown_settings();
        result.insert("editable".into(), Json::Bool(settings.is_some()));
        result.insert("custom".into(), Json::Bool(custom));
        result.insert(
            "placeholder".into(),
            Json::String(found.map_or(driver, |d| d.label).to_owned()),
        );
        result.insert("pending".into(), Json::Bool(false));
        let instance = settings
            .as_ref()
            .map(|s| instances::of(s, instance_id, driver))
            .unwrap_or_else(|| json!({}));
        let resettable = settings.as_ref().is_some_and(|s| {
            !custom
                && (at(s, "providerInstances").get(instance_id).is_some()
                    || !empty(at(at(s, "providers"), driver)))
        });
        result.insert("resettable".into(), Json::Bool(resettable));
        result.insert("label".into(), json!(str_at(&instance, "displayName")));
        result.insert(
            "accentColor".into(),
            json!(instances::accent(str_at(&instance, "accentColor"))),
        );
        result.insert(
            "fields".into(),
            Json::Array(
                found
                    .map(|d| fields(d, &object_at(&instance, "config")))
                    .unwrap_or_default(),
            ),
        );
        let environment = array_at(&instance, "environment");
        let secrets: Vec<Json> = found
            .map(|d| d.variables)
            .unwrap_or_default()
            .iter()
            .map(|variable| {
                let stored = environment
                    .iter()
                    .any(|v| at(v, "name").as_str() == Some(variable.name));
                json!({
                    "name": variable.name,
                    "label": variable.label,
                    "description": variable.description,
                    "placeholder": variable.placeholder,
                    "stored": stored,
                })
            })
            .collect();
        result.insert("secrets".into(), Json::Array(secrets));
        let rows = match self.variables.get(instance_id) {
            Some(rows) => rows.clone(),
            None => generic_rows(&instance, driver),
        };
        let variables: Vec<Json> = rows
            .iter()
            .map(|row| {
                let redacted = super::bool_at(row, "valueRedacted");
                json!({
                    "name": str_at(row, "name"),
                    "value": if redacted { "" } else { str_at(row, "value") },
                    "sensitive": super::bool_at(row, "sensitive"),
                    "redacted": redacted,
                    "invalid": invalid(row),
                    "placeholder": if redacted { "Stored secret, enter a new value to replace" } else { "value" },
                })
            })
            .collect();
        result.insert("variables".into(), Json::Array(variables));
        // Antigravity takes no custom models.
        let takes_models = driver != "antigravity";
        result.insert("takesModels".into(), Json::Bool(takes_models));
        result.insert(
            "customModels".into(),
            if takes_models {
                custom_models::read(at(at(&instance, "config"), "customModels"))
            } else {
                json!([])
            },
        );
        result.insert("modelPresets".into(), custom_models::presets(driver));
        result.insert(
            "copyFrom".into(),
            custom_models::copyable(array_at(&self.provider(instance_id), "models"), driver),
        );
        result.insert(
            "modelDraft".into(),
            self.model_draft
                .get(instance_id)
                .cloned()
                .unwrap_or(Json::Null),
        );
        result.insert(
            "modelError".into(),
            json!(
                self.model_error
                    .get(instance_id)
                    .cloned()
                    .unwrap_or_default()
            ),
        );
    }

    /// Instances added on the shown environment that it has yet to list.
    pub(super) fn pending_entries(&self, engine: &Engine) -> Vec<Json> {
        let (Some(settings), Some(_)) = (self.shown_settings(), &self.providers) else {
            return Vec::new();
        };
        let mut result = Vec::new();
        for (id, instance) in object_at(&settings, "providerInstances") {
            if !empty(&self.provider(&id)) {
                continue;
            }
            let driver = str_at(&instance, "driver");
            if driver.is_empty() {
                continue;
            }
            let mut provider = Map::new();
            provider.insert("instanceId".into(), Json::String(id.clone()));
            provider.insert("driver".into(), Json::String(driver.into()));
            super::insert_defined(&mut provider, "displayName", at(&instance, "displayName"));
            provider.insert(
                "enabled".into(),
                Json::Bool(at(&instance, "enabled").as_bool().unwrap_or(true)),
            );
            provider.insert("installed".into(), Json::Bool(true));
            let mut row = self.entry(engine, &Json::Object(provider));
            row.insert("headline".into(), json!("Checking provider status"));
            row.insert(
                "detail".into(),
                json!("Waiting for the server to report installation and authentication details."),
            );
            row.insert("pending".into(), Json::Bool(true));
            row.insert("account".into(), Json::Null);
            result.push(Json::Object(row));
        }
        result
    }

    pub(super) fn wizard_entry(&self) -> Json {
        let Some(wizard) = self.wizard.as_ref().filter(|_| self.open) else {
            return Json::Null;
        };
        // The ACP Registry is added by searching it.
        let choices: Vec<Json> = drivers::all()
            .iter()
            .filter(|d| d.id != REGISTRY)
            .map(|d| json!({"id": d.id, "label": d.label, "badge": d.badge}))
            .collect();
        let Some(driver) = drivers::find(&wizard.driver) else {
            return Json::Null;
        };
        let identity = wizard
            .identity
            .get(driver.id)
            .cloned()
            .map(Json::Object)
            .unwrap_or_else(|| json!({}));
        let label = match identity.get("label") {
            Some(label) => label.as_str().unwrap_or_default().to_owned(),
            None => driver.label.to_owned(),
        };
        let taken = self.taken();
        let id = match identity.get("instanceId") {
            Some(id) => id.as_str().unwrap_or_default().to_owned(),
            None => drivers::derive_id(driver.id, &label, &taken),
        };
        let config = wizard.config.get(driver.id).cloned().unwrap_or_default();
        json!({
            "step": wizard.step,
            "steps": steps(driver.id, wizard.manual),
            "registry": self.registry_entry(),
            "drivers": choices,
            "driver": driver.id,
            "driverLabel": driver.label,
            "label": label,
            "accentColor": str_at(&identity, "accentColor"),
            "instanceId": id,
            "instanceIdError": if wizard.attempted { drivers::validate_id(&id, &taken) } else { String::new() },
            "fields": fields(driver, &config),
            "saving": wizard.saving,
        })
    }
}
