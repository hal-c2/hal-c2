//! `usagePrices`, desktop-qt's UsagePricesController: custom model prices for
//! Usage. What a million tokens of a model cost is kept by each environment
//! in its settings (`usagePriceOverrides`, apps/server-ex
//! HalC2.Usage.Pricing), edited here for the environments the usage page has
//! chosen, all at once.
//!
//! Publishes `usagePrices`:
//!   {open, saving, error,
//!    targets [{id, label, status: "" | "Saved" | "Not saved", error}],
//!    rows [{model, isNew, removed, cells {<field>: {value, placeholder}}}],
//!    canRetry}
//! A cell's value is what was typed, else the price every chosen environment
//! agrees on; where they differ it is empty with the placeholder "Mixed"
//! ("Unavailable" while one cannot be read, "Automatic" where none sets one).
//! Fields: inputCostPerMillionTokens, outputCostPerMillionTokens,
//! cacheReadCostPerMillionTokens, cacheWriteCostPerMillionTokens.
//!
//! Actions: `usagePrices.open` and `.close`; `.add {model}`; `.edit {model,
//! field, value}`; `.remove {model}` marks a price to go back to automatic and
//! `.restore {model}` takes that back, both before saving; `.save` writes only
//! the edited cells to every chosen environment, each on its own, and `.retry`
//! ("Retry failed saves") writes again only where it failed.
//!
//! Each save is its own read and write of the environment's settings rather
//! than an `EnvironmentSettings::change`: a target settles on its own, and a
//! retry names only the ones that failed.

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::rc::Rc;

use ljos::prelude::Engine;
use serde_json::{Map, json};

use crate::bridge::Bridge;
use crate::controller::{Controller, Init, Me};
use crate::environment_settings::{EnvironmentSettings, same_json};
use crate::json::Json;
use crate::mc::{Mc, McError};
use crate::store;

const OVERRIDES: &str = "usagePriceOverrides";
/// How often a write refused as stale is read and edited again.
const STALE_RETRIES: u32 = 3;
const FAILED: &str = "Could not save. Try again.";

struct Field {
    key: &'static str,
    label: &'static str,
    optional: bool,
}

const FIELDS: [Field; 4] = [
    Field {
        key: "inputCostPerMillionTokens",
        label: "Input",
        optional: false,
    },
    Field {
        key: "outputCostPerMillionTokens",
        label: "Output",
        optional: false,
    },
    Field {
        key: "cacheReadCostPerMillionTokens",
        label: "Cache read",
        optional: true,
    },
    Field {
        key: "cacheWriteCostPerMillionTokens",
        label: "Cache write",
        optional: true,
    },
];

/// An environment the usage page can price for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Environment {
    pub id: String,
    /// Empty shows the id (or "This machine" for the MC's own).
    pub label: String,
    pub online: bool,
}

/// The environments a test says the shell knows, in place of the store's.
#[derive(Default)]
struct Known(RefCell<Option<Vec<Environment>>>);

/// Says which environments exist, in place of the store's (or, without a
/// store, the MC's own alone).
pub fn set_environments(engine: &Engine, environments: Vec<Environment>) {
    *engine.extension::<Known>().0.borrow_mut() = Some(environments);
}

#[derive(Default)]
struct Draft {
    model: String,
    is_new: bool,
    removed: bool,
    /// By field, as typed.
    values: HashMap<String, String>,
}

pub struct UsagePrices {
    bridge: Bridge,
    me: Me<UsagePrices>,
    mc: Rc<dyn Mc>,
    settings: EnvironmentSettings,
    active: bool,
    open: bool,
    targets: Vec<String>,
    drafts: Vec<Draft>,
    /// Each target's last save: empty when saved, else why not.
    results: BTreeMap<String, String>,
    writing: BTreeSet<String>,
    error: String,
    /// Which targets were online when last followed: one that comes back is
    /// read again.
    online: BTreeSet<String>,
}

impl Controller for UsagePrices {
    fn new(init: Init<'_, Self>) -> Self {
        let settings = EnvironmentSettings::new(init.mc.clone());
        let me = init.me.clone();
        settings.on_changed(move |engine| me.run(engine, |c, engine| c.publish(engine)));
        UsagePrices {
            bridge: init.bridge,
            me: init.me,
            mc: init.mc,
            settings,
            active: false,
            open: false,
            targets: Vec::new(),
            drafts: Vec::new(),
            results: BTreeMap::new(),
            writing: BTreeSet::new(),
            error: String::new(),
            online: BTreeSet::new(),
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        // An environment that comes back is read again, so it can be saved to.
        let me = self.me.clone();
        self.mc.on_ready_changed(Box::new(move |engine, _| {
            me.run(engine, |c, engine| c.environments_changed(engine));
        }));
        let me = self.me.clone();
        store::on_changed(engine, move |engine| {
            me.run(engine, |c, engine| c.environments_changed(engine));
        });
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !self.active || !action.starts_with("usagePrices.") {
            return false;
        }
        let text = |key: &str| payload.get(key).and_then(Json::as_str).unwrap_or_default();
        let model = text("model").trim().to_owned();
        match action {
            "usagePrices.open" => self.set_open(engine, true),
            "usagePrices.close" => self.set_open(engine, false),
            _ if !self.open => {}
            "usagePrices.add" => {
                if model.is_empty() {
                    self.error = "Enter a model ID.".into();
                } else {
                    self.error.clear();
                    let known = self
                        .targets
                        .iter()
                        .any(|id| self.prices(engine, id).0.contains_key(&model));
                    self.draft(&model).is_new = !known;
                }
                self.publish(engine);
            }
            "usagePrices.edit" => {
                if !model.is_empty() {
                    let (field, value) = (text("field").to_owned(), text("value").to_owned());
                    self.draft(&model).values.insert(field, value);
                    self.publish(engine);
                }
            }
            "usagePrices.remove" | "usagePrices.restore" => {
                if !model.is_empty() {
                    self.draft(&model).removed = action == "usagePrices.remove";
                    self.publish(engine);
                }
            }
            "usagePrices.save" => self.save(engine, self.targets.clone()),
            "usagePrices.retry" => {
                let failed: Vec<String> = self
                    .targets
                    .iter()
                    .filter(|id| self.results.get(*id).is_some_and(|r| !r.is_empty()))
                    .cloned()
                    .collect();
                if !failed.is_empty() {
                    self.save(engine, failed);
                }
            }
            _ => return false,
        }
        true
    }
}

impl UsagePrices {
    fn environments(&self, engine: &Engine) -> Vec<Environment> {
        if let Some(known) = engine.extension::<Known>().0.borrow().clone() {
            return known;
        }
        if store::get(engine).is_some() {
            return store::with(engine, |s| {
                s.environments()
                    .into_iter()
                    .map(|id| Environment {
                        label: s
                            .environment(&id)
                            .get("label")
                            .and_then(|l| l.as_str())
                            .unwrap_or_default()
                            .to_owned(),
                        online: s.environment_online(&id),
                        id,
                    })
                    .collect()
            });
        }
        match self.mc.environment() {
            id if id.is_empty() => Vec::new(),
            id => vec![Environment {
                id,
                label: String::new(),
                online: self.mc.is_ready(),
            }],
        }
    }

    fn online(&self, engine: &Engine, id: &str) -> bool {
        self.environments(engine)
            .iter()
            .any(|e| e.id == id && e.online)
    }

    fn label(&self, engine: &Engine, id: &str) -> String {
        let label = self
            .environments(engine)
            .into_iter()
            .find(|e| e.id == id)
            .map(|e| e.label)
            .unwrap_or_default();
        if !label.is_empty() {
            label
        } else if id == self.mc.environment() {
            "This machine".into()
        } else {
            id.to_owned()
        }
    }

    /// The environments the usage page has chosen: the one it is filtered to,
    /// else all; this machine first, the rest by name.
    fn chosen(&self, engine: &Engine) -> Vec<String> {
        let filter = self
            .bridge
            .published(engine, "usage")
            .and_then(|u| u.get("environmentId")?.as_str().map(str::to_owned))
            .unwrap_or_default();
        let own = self.mc.environment();
        let mut targets: Vec<(bool, String, String)> = self
            .environments(engine)
            .into_iter()
            .filter(|e| filter.is_empty() || e.id == filter)
            .map(|e| (e.id != own, self.label(engine, &e.id), e.id))
            .collect();
        targets.sort();
        targets.into_iter().map(|(_, _, id)| id).collect()
    }

    fn environments_changed(&mut self, engine: &Engine) {
        if !self.open {
            return;
        }
        // One paired while the dialog is open joins it.
        let targets = self.chosen(engine);
        let moved = targets != self.targets;
        self.targets = targets;
        let online: BTreeSet<String> = self
            .targets
            .iter()
            .filter(|id| self.online(engine, id))
            .cloned()
            .collect();
        if moved || online != self.online {
            self.follow(engine);
        }
        self.publish(engine);
    }

    fn set_open(&mut self, engine: &Engine, open: bool) {
        if open == self.open {
            return;
        }
        self.open = open;
        self.drafts.clear();
        self.results.clear();
        self.error.clear();
        self.targets = if open {
            self.chosen(engine)
        } else {
            Vec::new()
        };
        self.follow(engine);
        self.publish(engine);
    }

    fn follow(&mut self, engine: &Engine) {
        self.online = self
            .targets
            .iter()
            .filter(|id| self.online(engine, id))
            .cloned()
            .collect();
        // Afresh: a subscription an offline environment refused is not sent again.
        self.settings.set_targets(&[]);
        self.settings.set_targets(&self.targets);
    }

    fn draft(&mut self, model: &str) -> &mut Draft {
        let at = match self.drafts.iter().position(|d| d.model == model) {
            Some(at) => at,
            None => {
                self.drafts.push(Draft {
                    model: model.to_owned(),
                    ..Draft::default()
                });
                self.drafts.len() - 1
            }
        };
        &mut self.drafts[at]
    }

    /// The target's price overrides, and whether its settings have arrived.
    fn prices(&self, _: &Engine, id: &str) -> (Map<String, Json>, bool) {
        let settings = self.settings.settings(id);
        let overrides = settings
            .as_ref()
            .and_then(|s| s.get(OVERRIDES)?.as_object().cloned())
            .unwrap_or_default();
        (overrides, settings.is_some())
    }

    /// The target's overrides with the drafts applied; the error says why a
    /// draft cannot be saved there (and then the overrides come back as they
    /// were). Only edited cells replace rates; the others keep each
    /// environment's own.
    fn edited(
        &self,
        current: &Map<String, Json>,
        place: &str,
    ) -> (Map<String, Json>, Option<String>) {
        let mut next = current.clone();
        for draft in &self.drafts {
            if draft.removed {
                next.remove(&draft.model);
                continue;
            }
            if draft.values.is_empty() {
                continue;
            }
            let original = current.get(&draft.model).and_then(Json::as_object);
            let mut price = Map::new();
            for field in &FIELDS {
                let typed = draft.values.get(field.key).cloned();
                let text = typed
                    .unwrap_or_else(|| original.map(|o| shown(o, field.key)).unwrap_or_default())
                    .trim()
                    .to_owned();
                if text.is_empty() {
                    if field.optional {
                        continue;
                    }
                    return (
                        current.clone(),
                        Some(format!("{} is required on {place}.", field.label)),
                    );
                }
                let Some(value) = price_of(&text) else {
                    return (
                        current.clone(),
                        Some("Use non-negative numbers for prices.".into()),
                    );
                };
                price.insert(field.key.to_owned(), value);
            }
            next.insert(draft.model.clone(), Json::Object(price));
        }
        (next, None)
    }

    fn save(&mut self, engine: &Engine, targets: Vec<String>) {
        if !self.writing.is_empty() {
            return;
        }
        // A draft that cannot be saved somewhere stops the save before
        // anything is written.
        self.error.clear();
        for id in &targets {
            let (current, known) = self.prices(engine, id);
            if !known {
                continue;
            }
            if let (_, Some(error)) = self.edited(&current, &self.label(engine, id)) {
                self.error = error;
                return self.publish(engine);
            }
        }
        for id in &targets {
            self.results.remove(id);
            self.writing.insert(id.clone());
        }
        self.publish(engine);
        // Each destination settles on its own.
        for id in &targets {
            self.write(id, STALE_RETRIES);
        }
    }

    fn write(&self, id: &str, retries: u32) {
        let me = self.me.clone();
        let target = id.to_owned();
        self.mc.call(
            id,
            "hal-c2.readSettings",
            json!({}),
            Box::new(move |engine, result| {
                me.clone().run(engine, |c, engine| {
                    c.read(engine, &target, retries, result, me)
                });
            }),
        );
    }

    fn read(
        &mut self,
        engine: &Engine,
        id: &str,
        retries: u32,
        result: Result<Json, McError>,
        me: Me<UsagePrices>,
    ) {
        let Ok(read) = result else {
            return self.settled(engine, id, FAILED);
        };
        let mut settings = read.get("settings").cloned().unwrap_or_else(|| json!({}));
        let current = settings
            .get(OVERRIDES)
            .and_then(Json::as_object)
            .cloned()
            .unwrap_or_default();
        let (next, _) = self.edited(&current, &self.label(engine, id));
        if same_json(&Json::Object(next.clone()), &Json::Object(current)) {
            return self.settled(engine, id, "");
        }
        if let Some(map) = settings.as_object_mut() {
            if next.is_empty() {
                map.remove(OVERRIDES);
            } else {
                map.insert(OVERRIDES.into(), Json::Object(next));
            }
        }
        let payload = json!({
            "settings": settings,
            "version": read.get("version").cloned().unwrap_or(Json::Null),
        });
        let target = id.to_owned();
        self.mc.call(
            id,
            "hal-c2.writeSettings",
            payload,
            Box::new(move |engine, result| {
                me.clone().run(engine, |c, engine| match result {
                    Ok(_) => c.settled(engine, &target, ""),
                    // Another client saved in between: read and edit again.
                    Err(e) if retries > 0 && stale(&e) => c.write(&target, retries - 1),
                    Err(_) => c.settled(engine, &target, FAILED),
                });
            }),
        );
    }

    fn settled(&mut self, engine: &Engine, id: &str, error: &str) {
        self.writing.remove(id);
        self.results.insert(id.to_owned(), error.to_owned());
        if self.writing.is_empty() {
            // Saved everywhere, the edits are what the environments hold now.
            let failed = self.results.values().any(|r| !r.is_empty());
            if !failed && self.results.len() == self.targets.len() {
                self.drafts.clear();
            }
        }
        self.publish(engine);
    }

    fn publish(&self, engine: &Engine) {
        if !self.active {
            return;
        }
        let mut any_failed = false;
        let targets: Vec<Json> = self
            .targets
            .iter()
            .map(|id| {
                let result = self.results.get(id);
                let error = result.cloned().unwrap_or_default();
                any_failed |= !error.is_empty();
                let status = match result {
                    None => "",
                    Some(e) if e.is_empty() => "Saved",
                    Some(_) => "Not saved",
                };
                json!({ "id": id, "label": self.label(engine, id), "status": status, "error": error })
            })
            .collect();

        // Every model a chosen environment prices, by name, then the ones
        // being added.
        let mut models: Vec<String> = Vec::new();
        let mut unavailable = false;
        for id in &self.targets {
            let (current, known) = self.prices(engine, id);
            unavailable |= !known;
            for model in current.keys() {
                if !models.contains(model) {
                    models.push(model.clone());
                }
            }
        }
        models.sort();
        for draft in &self.drafts {
            if !models.contains(&draft.model) {
                models.push(draft.model.clone());
            }
        }
        let rows: Vec<Json> = models
            .iter()
            .map(|model| {
                let draft = self.drafts.iter().find(|d| &d.model == model);
                let mut cells = Map::new();
                for field in &FIELDS {
                    // None where an environment does not price the model at all.
                    let values: Vec<Option<String>> = self
                        .targets
                        .iter()
                        .map(|id| {
                            let (current, _) = self.prices(engine, id);
                            current.get(model).map(|price| {
                                price
                                    .as_object()
                                    .map(|p| shown(p, field.key))
                                    .unwrap_or_default()
                            })
                        })
                        .collect();
                    let priced = values.iter().any(Option::is_some);
                    let (mut value, placeholder) = if unavailable {
                        (String::new(), "Unavailable")
                    } else if values.iter().any(|v| v != &values[0]) {
                        (String::new(), "Mixed")
                    } else {
                        let placeholder = if !priced {
                            "Automatic"
                        } else if field.optional {
                            "Input rate"
                        } else {
                            "0.00"
                        };
                        (
                            values.first().cloned().flatten().unwrap_or_default(),
                            placeholder,
                        )
                    };
                    if let Some(typed) = draft.and_then(|d| d.values.get(field.key)) {
                        value = typed.clone();
                    }
                    cells.insert(
                        field.key.to_owned(),
                        json!({ "value": value, "placeholder": placeholder }),
                    );
                }
                json!({
                    "model": model,
                    "isNew": draft.is_some_and(|d| d.is_new),
                    "removed": draft.is_some_and(|d| d.removed),
                    "cells": cells,
                })
            })
            .collect();
        self.bridge.publish(
            engine,
            "usagePrices",
            json!({
                "open": self.open,
                "saving": !self.writing.is_empty(),
                "error": self.error,
                "targets": targets,
                "rows": rows,
                "canRetry": any_failed && self.writing.is_empty(),
            }),
        );
    }
}

fn stale(error: &McError) -> bool {
    error.detail.get("_tag").and_then(Json::as_str) == Some("StaleSettings")
}

/// A saved rate as the field shows it; empty when the price does not set it.
fn shown(price: &Map<String, Json>, field: &str) -> String {
    match price.get(field) {
        Some(Json::Number(n)) => n.as_f64().map(general).unwrap_or_default(),
        _ => String::new(),
    }
}

/// `QString::number(value, 'g', 15)`: up to 15 significant digits, no
/// trailing zeros, an exponent only for very large and very small numbers.
pub fn general(value: f64) -> String {
    if !value.is_finite() {
        return value.to_string();
    }
    if value == 0.0 {
        return "0".into();
    }
    let sci = format!("{value:.14e}");
    let (mantissa, exponent) = sci.split_once('e').unwrap_or((&sci, "0"));
    let exponent: i32 = exponent.parse().unwrap_or(0);
    let trim = |s: String| {
        if s.contains('.') {
            s.trim_end_matches('0').trim_end_matches('.').to_owned()
        } else {
            s
        }
    };
    if !(-4..15).contains(&exponent) {
        let sign = if exponent < 0 { '-' } else { '+' };
        return format!("{}e{sign}{:02}", trim(mantissa.to_owned()), exponent.abs());
    }
    trim(format!("{value:.*}", (14 - exponent).max(0) as usize))
}

/// The price a field's text means: a non-negative decimal number
/// (`^(\d+(\.\d*)?|\.\d+)(e[+-]?\d+)?$`, either case), as a JSON number.
fn price_of(text: &str) -> Option<Json> {
    let lower = text.to_ascii_lowercase();
    let (number, exponent) = match lower.split_once('e') {
        Some((n, e)) => (n, Some(e)),
        None => (lower.as_str(), None),
    };
    let digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    let (whole, fraction) = number
        .split_once('.')
        .map_or((number, None), |(w, f)| (w, Some(f)));
    let number_ok = match fraction {
        None => digits(whole),
        Some(f) => {
            (digits(whole) && (f.is_empty() || digits(f))) || (whole.is_empty() && digits(f))
        }
    };
    let exponent_ok = exponent.is_none_or(|e| digits(e.strip_prefix(['+', '-']).unwrap_or(e)));
    if !number_ok || !exponent_ok {
        return None;
    }
    let value: f64 = lower.parse().ok().filter(|v: &f64| v.is_finite())?;
    // A whole price goes over the wire as one, as QJsonValue writes it.
    if value.fract() == 0.0 && value < 9_007_199_254_740_992.0 {
        return Some(json!(value as i64));
    }
    serde_json::Number::from_f64(value).map(Json::Number)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn general_prints_like_qstring_number() {
        for (value, text) in [
            (3.0, "3"),
            (0.3, "0.3"),
            (1.25, "1.25"),
            (15.0, "15"),
            (0.1 + 0.2, "0.3"),
            (1e-5, "1e-05"),
            (0.0001, "0.0001"),
            (1.5e21, "1.5e+21"),
            (123456789012345.0, "123456789012345"),
            (0.0, "0"),
        ] {
            assert_eq!(general(value), text, "{value}");
        }
    }

    #[test]
    fn a_price_is_a_non_negative_decimal() {
        for text in ["3", "0.30", "5.", ".5", "1e3", "1E+3", "2.5e-1", "0"] {
            assert!(price_of(text).is_some(), "{text}");
        }
        for text in [
            "", "-1", "+1", "1e", "e3", ".", "1.2.3", "1,5", "0x10", "NaN", "inf", "1e999", "1 2",
        ] {
            assert_eq!(price_of(text), None, "{text}");
        }
        assert_eq!(price_of("3"), Some(json!(3)));
        assert_eq!(price_of("1e3"), Some(json!(1000)));
        assert_eq!(price_of("0.25"), Some(json!(0.25)));
    }
}
