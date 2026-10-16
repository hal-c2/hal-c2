//! The Usage page's custom model prices, driven as the dialog drives them:
//! through `Shell.dispatch` and `Shell.state`, over a scripted MC that holds
//! each environment's settings document.

mod common;
#[path = "support/scripted_mc.rs"]
mod scripted_mc;

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;

use common::shell;
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controllers::usage_prices::{Environment, set_environments};
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::McError;
use ljos::prelude::Engine;
use scripted_mc::{ScriptedMc, stale};
use serde_json::json;

const EMPTY: &str = "import QtQuick\nItem {}\n";
const INPUT: &str = "inputCostPerMillionTokens";
const OUTPUT: &str = "outputCostPerMillionTokens";
const CACHE_READ: &str = "cacheReadCostPerMillionTokens";

fn published(engine: &Engine, key: &str) -> Json {
    Bridge::of(engine)
        .published(engine, key)
        .unwrap_or(Json::Null)
}

fn dispatch(engine: &Engine, action: &str, payload: Json) {
    Bridge::of(engine).dispatch(engine, action, payload);
}

fn prices(engine: &Engine) -> Json {
    published(engine, "usagePrices")
}

fn shape(environment: &str) -> Json {
    json!({ "type": "config", "environment": environment })
}

/// The documents the scripted MC serves, by environment, and how its writes
/// should go wrong.
#[derive(Default)]
struct Hosts {
    settings: BTreeMap<String, Json>,
    version: u64,
    /// Environments whose writes are refused.
    refusing: Vec<String>,
    /// Writes refused as stale before one is taken.
    stale: u32,
}

struct World {
    engine: Engine,
    mc: Rc<ScriptedMc>,
    hosts: Rc<RefCell<Hosts>>,
}

impl World {
    /// A shell over environments `ids` (the first is the MC's own), each
    /// holding `overrides` in its settings.
    fn new(environments: &[(&str, &str, Json)]) -> World {
        let hosts = Rc::new(RefCell::new(Hosts::default()));
        for (id, _, overrides) in environments {
            hosts.borrow_mut().settings.insert(
                id.to_string(),
                json!({ "other": id, "usagePriceOverrides": overrides }),
            );
        }
        let mc = ScriptedMc::new({
            let hosts = hosts.clone();
            move |env, method, payload| {
                let mut hosts = hosts.borrow_mut();
                match method {
                    // The shell reports activity on its own; not under test.
                    "server.reportClientActivity" => Ok(json!({})),
                    "hal-c2.readSettings" => Ok(json!({
                        "settings": hosts.settings[env],
                        "version": hosts.version,
                    })),
                    "hal-c2.writeSettings" if hosts.refusing.iter().any(|r| r == env) => {
                        Err(McError::new("Disk full."))
                    }
                    "hal-c2.writeSettings" if hosts.stale > 0 => {
                        hosts.stale -= 1;
                        hosts.version += 1;
                        Err(stale())
                    }
                    "hal-c2.writeSettings" => {
                        assert_eq!(payload["version"], json!(hosts.version), "{env}");
                        hosts
                            .settings
                            .insert(env.to_owned(), payload["settings"].clone());
                        Ok(json!({}))
                    }
                    other => panic!("{other}"),
                }
            }
        });
        *mc.environment.borrow_mut() = environments[0].0.to_owned();
        let (engine, _) = shell(EMPTY, mc.clone());
        set_environments(
            &engine,
            environments
                .iter()
                .map(|(id, label, _)| Environment {
                    id: id.to_string(),
                    label: label.to_string(),
                    online: true,
                })
                .collect(),
        );
        World { engine, mc, hosts }
    }

    fn one(overrides: Json) -> World {
        World::new(&[("env-1", "", overrides)])
    }

    fn act(&self, action: &str, payload: Json) {
        dispatch(&self.engine, action, payload);
    }

    fn edit(&self, model: &str, field: &str, value: &str) {
        self.act(
            "usagePrices.edit",
            json!({ "model": model, "field": field, "value": value }),
        );
    }

    /// The MC sends each followed environment's settings document, as the
    /// `config` shape does.
    fn send_settings(&self) {
        let hosts = self.hosts.borrow();
        for (id, settings) in &hosts.settings {
            self.mc.send(
                &self.engine,
                &shape(id),
                json!({ "t": "config.settings", "settings": settings }),
            );
        }
    }

    /// The calls the dialog made, leaving out the shell's own.
    fn calls(&self) -> Vec<(String, String, Json)> {
        self.mc
            .calls
            .borrow()
            .iter()
            .filter(|(_, method, _)| method != "server.reportClientActivity")
            .cloned()
            .collect()
    }

    fn methods(&self) -> Vec<String> {
        self.calls().into_iter().map(|(_, m, _)| m).collect()
    }

    fn open(&self) {
        self.act("usagePrices.open", json!({}));
        self.send_settings();
    }

    fn deliver(&self) {
        self.mc.deliver(&self.engine);
    }

    fn row(&self, model: &str) -> Json {
        prices(&self.engine)["rows"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["model"] == model)
            .unwrap_or_else(|| panic!("no row for {model}: {}", prices(&self.engine)))
            .clone()
    }

    fn cell(&self, model: &str, field: &str) -> (String, String) {
        let cell = &self.row(model)["cells"][field];
        (
            cell["value"].as_str().unwrap().to_owned(),
            cell["placeholder"].as_str().unwrap().to_owned(),
        )
    }

    fn overrides(&self, env: &str) -> Json {
        self.hosts.borrow().settings[env]["usagePriceOverrides"].clone()
    }
}

fn cell(value: &str, placeholder: &str) -> (String, String) {
    (value.into(), placeholder.into())
}

#[test]
fn it_is_closed_until_opened_and_follows_the_chosen_environments() {
    let w = World::one(json!({}));
    let state = prices(&w.engine);
    assert_eq!(state["open"], false);
    assert_eq!(state["rows"], json!([]));
    assert_eq!(state["targets"], json!([]));
    // Edits to a closed dialog are taken and ignored.
    w.edit("m", INPUT, "1");
    assert_eq!(prices(&w.engine)["rows"], json!([]));
    assert!(w.mc.subscribed().is_empty());

    w.act("usagePrices.open", json!({}));
    assert_eq!(w.mc.subscribed(), [shape("env-1")]);
    let state = prices(&w.engine);
    assert_eq!(state["open"], true);
    assert_eq!(
        state["targets"],
        json!([{ "id": "env-1", "label": "This machine", "status": "", "error": "" }])
    );

    w.act("usagePrices.close", json!({}));
    assert!(w.mc.subscribed().is_empty());
    assert_eq!(prices(&w.engine)["open"], false);
}

#[test]
fn each_model_shows_the_rate_its_environments_agree_on() {
    let w = World::one(json!({
        "gpt-x": { INPUT: 3, OUTPUT: 15.5 },
        "claude-y": { INPUT: 0.3, OUTPUT: 1.25, CACHE_READ: 0.03 },
    }));
    w.open();
    let models: Vec<_> = prices(&w.engine)["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["model"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(models, ["claude-y", "gpt-x"]);
    assert_eq!(w.cell("gpt-x", INPUT), cell("3", "0.00"));
    assert_eq!(w.cell("gpt-x", OUTPUT), cell("15.5", "0.00"));
    // A rate the price leaves out is empty, and falls back to the input rate.
    assert_eq!(w.cell("gpt-x", CACHE_READ), cell("", "Input rate"));
    assert_eq!(w.cell("claude-y", CACHE_READ), cell("0.03", "Input rate"));
}

#[test]
fn rates_that_differ_are_mixed_and_an_unread_environment_is_unavailable() {
    let w = World::new(&[
        (
            "env-1",
            "",
            json!({ "m": { INPUT: 1, OUTPUT: 2 }, "only-here": { INPUT: 5, OUTPUT: 6 } }),
        ),
        (
            "env-2",
            "Build box",
            json!({ "m": { INPUT: 1, OUTPUT: 3 } }),
        ),
    ]);
    w.act("usagePrices.open", json!({}));
    // The first answers; the second has not.
    let hosts = w.hosts.borrow();
    w.mc.send(
        &w.engine,
        &shape("env-1"),
        json!({ "t": "config.settings", "settings": hosts.settings["env-1"] }),
    );
    drop(hosts);
    assert_eq!(w.cell("m", INPUT), cell("", "Unavailable"));

    w.send_settings();
    assert_eq!(w.cell("m", INPUT), cell("1", "0.00"));
    assert_eq!(w.cell("m", OUTPUT), cell("", "Mixed"));
    // Priced on one machine only is a difference too.
    assert_eq!(w.cell("only-here", INPUT), cell("", "Mixed"));
    // This machine is listed first, then the rest by name.
    let ids: Vec<_> = prices(&w.engine)["targets"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["label"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(ids, ["This machine", "Build box"]);
}

#[test]
fn a_model_nobody_prices_is_automatic() {
    let w = World::one(json!({}));
    w.open();
    w.act("usagePrices.add", json!({ "model": "  new-model " }));
    let row = w.row("new-model");
    assert_eq!(row["isNew"], true);
    assert_eq!(w.cell("new-model", INPUT), cell("", "Automatic"));
    assert_eq!(w.cell("new-model", CACHE_READ), cell("", "Automatic"));

    // A model an environment already prices is not new.
    let w = World::one(json!({ "known": { INPUT: 1, OUTPUT: 2 } }));
    w.open();
    w.act("usagePrices.add", json!({ "model": "known" }));
    assert_eq!(w.row("known")["isNew"], false);

    w.act("usagePrices.add", json!({ "model": " " }));
    assert_eq!(prices(&w.engine)["error"], "Enter a model ID.");
    w.act("usagePrices.add", json!({ "model": "other" }));
    assert_eq!(prices(&w.engine)["error"], "");
}

#[test]
fn a_save_writes_only_the_edited_cells_and_keeps_the_rest_of_the_settings() {
    let w = World::one(json!({
        "gpt-x": { INPUT: 3, OUTPUT: 15, CACHE_READ: 1 },
        "untouched": { INPUT: 9, OUTPUT: 9 },
    }));
    w.open();
    w.edit("gpt-x", OUTPUT, " 20 ");
    w.edit("gpt-x", CACHE_READ, "");
    assert_eq!(w.cell("gpt-x", OUTPUT).0, " 20 ");
    w.act("usagePrices.add", json!({ "model": "fresh" }));
    w.edit("fresh", INPUT, "1e1");
    w.edit("fresh", OUTPUT, "0.5");

    w.act("usagePrices.save", json!({}));
    let state = prices(&w.engine);
    assert_eq!(state["saving"], true);
    // Nothing is written until the MC answers.
    assert_eq!(w.methods(), ["hal-c2.readSettings"]);
    w.deliver();
    assert_eq!(
        w.overrides("env-1"),
        json!({
            "gpt-x": { INPUT: 3, OUTPUT: 20 },
            "untouched": { INPUT: 9, OUTPUT: 9 },
            "fresh": { INPUT: 10, OUTPUT: 0.5 },
        })
    );
    assert_eq!(w.hosts.borrow().settings["env-1"]["other"], "env-1");

    let state = prices(&w.engine);
    assert_eq!(state["saving"], false);
    assert_eq!(state["canRetry"], false);
    assert_eq!(state["targets"][0]["status"], "Saved");
    // Saved everywhere, so the edits are what the environments hold now.
    w.send_settings();
    assert_eq!(w.cell("gpt-x", OUTPUT), cell("20", "0.00"));
    assert_eq!(w.row("fresh")["isNew"], false);
}

#[test]
fn a_price_that_cannot_be_saved_stops_the_save_before_anything_is_written() {
    let w = World::new(&[
        ("env-1", "", json!({ "m": { INPUT: 1, OUTPUT: 2 } })),
        ("env-2", "Build box", json!({})),
    ]);
    w.open();
    // Fine for the first, which has an output rate; the second has none.
    w.edit("m", INPUT, "4");
    w.act("usagePrices.save", json!({}));
    assert_eq!(
        prices(&w.engine)["error"],
        "Output is required on Build box."
    );
    assert!(w.methods().is_empty());
    assert_eq!(prices(&w.engine)["saving"], false);

    for bad in ["-1", "abc", "1e", "1,5"] {
        w.edit("m", OUTPUT, bad);
        w.act("usagePrices.save", json!({}));
        assert_eq!(
            prices(&w.engine)["error"],
            "Use non-negative numbers for prices.",
            "{bad}"
        );
    }
    assert!(w.methods().is_empty());

    w.edit("m", OUTPUT, "6");
    w.act("usagePrices.save", json!({}));
    assert_eq!(prices(&w.engine)["error"], "");
    w.deliver();
    assert_eq!(
        w.overrides("env-1"),
        json!({ "m": { INPUT: 4, OUTPUT: 6 } })
    );
    assert_eq!(
        w.overrides("env-2"),
        json!({ "m": { INPUT: 4, OUTPUT: 6 } })
    );
}

#[test]
fn removing_a_price_returns_the_model_to_automatic_and_can_be_taken_back() {
    let w = World::one(json!({
        "a": { INPUT: 1, OUTPUT: 2 },
        "b": { INPUT: 3, OUTPUT: 4 },
    }));
    w.open();
    w.act("usagePrices.remove", json!({ "model": "a" }));
    assert_eq!(w.row("a")["removed"], true);
    w.act("usagePrices.restore", json!({ "model": "a" }));
    assert_eq!(w.row("a")["removed"], false);

    w.act("usagePrices.remove", json!({ "model": "a" }));
    w.act("usagePrices.save", json!({}));
    w.deliver();
    assert_eq!(
        w.overrides("env-1"),
        json!({ "b": { INPUT: 3, OUTPUT: 4 } })
    );

    // The last one going takes the setting with it.
    w.act("usagePrices.open", json!({}));
    w.act("usagePrices.close", json!({}));
    w.open();
    w.act("usagePrices.remove", json!({ "model": "b" }));
    w.act("usagePrices.save", json!({}));
    w.deliver();
    assert!(
        w.hosts.borrow().settings["env-1"]
            .get("usagePriceOverrides")
            .is_none()
    );
}

#[test]
fn an_edit_that_changes_nothing_writes_nothing() {
    let w = World::one(json!({ "m": { INPUT: 1, OUTPUT: 2 } }));
    w.open();
    w.edit("m", INPUT, "1.0");
    w.act("usagePrices.save", json!({}));
    w.deliver();
    assert_eq!(w.methods(), ["hal-c2.readSettings"]);
    assert_eq!(prices(&w.engine)["targets"][0]["status"], "Saved");
}

#[test]
fn one_failing_environment_does_not_stop_the_others_and_can_be_retried_alone() {
    let w = World::new(&[
        ("env-1", "", json!({})),
        ("env-2", "Build box", json!({})),
        ("env-3", "Cloud", json!({})),
    ]);
    w.hosts.borrow_mut().refusing.push("env-2".into());
    w.open();
    w.act("usagePrices.add", json!({ "model": "m" }));
    w.edit("m", INPUT, "1");
    w.edit("m", OUTPUT, "2");
    w.act("usagePrices.save", json!({}));
    w.deliver();

    let state = prices(&w.engine);
    let statuses: Vec<_> = state["targets"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| {
            (
                t["label"].as_str().unwrap(),
                t["status"].as_str().unwrap(),
                t["error"].as_str().unwrap(),
            )
        })
        .collect();
    assert_eq!(
        statuses,
        [
            ("This machine", "Saved", ""),
            ("Build box", "Not saved", "Could not save. Try again."),
            ("Cloud", "Saved", ""),
        ]
    );
    assert_eq!(state["canRetry"], true);
    assert_eq!(state["saving"], false);
    // The edits stay for the one that failed.
    assert_eq!(w.cell("m", INPUT).0, "1");
    assert_eq!(
        w.overrides("env-3"),
        json!({ "m": { INPUT: 1, OUTPUT: 2 } })
    );

    w.hosts.borrow_mut().refusing.clear();
    let before = w.calls().len();
    w.act("usagePrices.retry", json!({}));
    w.deliver();
    let retried: Vec<_> = w.calls()[before..]
        .iter()
        .map(|(env, _, _)| env.clone())
        .collect();
    assert_eq!(retried, ["env-2", "env-2"]);
    let state = prices(&w.engine);
    assert_eq!(state["targets"][1]["status"], "Saved");
    assert_eq!(state["canRetry"], false);
    assert_eq!(
        w.overrides("env-2"),
        json!({ "m": { INPUT: 1, OUTPUT: 2 } })
    );

    // Retrying with nothing failed is nothing.
    w.act("usagePrices.retry", json!({}));
    assert_eq!(w.calls().len(), before + 2);
}

#[test]
fn a_write_another_client_got_in_before_is_read_and_edited_again() {
    let w = World::one(json!({ "m": { INPUT: 1, OUTPUT: 2 } }));
    w.open();
    w.hosts.borrow_mut().stale = 2;
    w.edit("m", INPUT, "5");
    w.act("usagePrices.save", json!({}));
    w.deliver();
    assert_eq!(
        w.overrides("env-1"),
        json!({ "m": { INPUT: 5, OUTPUT: 2 } })
    );
    assert_eq!(prices(&w.engine)["targets"][0]["status"], "Saved");
    assert_eq!(w.mc.payloads("hal-c2.readSettings").len(), 3);

    // Stale beyond the retries is a failed save.
    w.hosts.borrow_mut().stale = 10;
    w.edit("m", INPUT, "6");
    w.act("usagePrices.save", json!({}));
    w.deliver();
    assert_eq!(prices(&w.engine)["targets"][0]["status"], "Not saved");
}

#[test]
fn a_save_while_saving_is_ignored_and_closing_forgets_the_drafts() {
    let w = World::one(json!({}));
    w.open();
    w.act("usagePrices.add", json!({ "model": "m" }));
    w.edit("m", INPUT, "1");
    w.edit("m", OUTPUT, "2");
    w.act("usagePrices.save", json!({}));
    w.act("usagePrices.save", json!({}));
    assert_eq!(w.methods(), ["hal-c2.readSettings"]);
    w.deliver();

    w.act("usagePrices.close", json!({}));
    w.act("usagePrices.open", json!({}));
    w.send_settings();
    let state = prices(&w.engine);
    assert_eq!(state["targets"][0]["status"], "");
    assert_eq!(state["error"], "");
    assert_eq!(w.cell("m", INPUT), cell("1", "0.00"));
}

#[test]
fn an_environment_that_comes_back_is_followed_afresh() {
    let w = World::one(json!({}));
    w.open();
    assert_eq!(w.mc.subscribed().len(), 1);
    w.mc.set_ready(&w.engine, false);
    w.mc.set_ready(&w.engine, true);
    // Online is the same set again here, so it is not resubscribed.
    assert_eq!(w.mc.subscribed().len(), 1);

    // A machine paired while the dialog is open joins it.
    set_environments(
        &w.engine,
        vec![
            Environment {
                id: "env-1".into(),
                label: String::new(),
                online: true,
            },
            Environment {
                id: "env-2".into(),
                label: "Build box".into(),
                online: true,
            },
        ],
    );
    w.mc.set_ready(&w.engine, false);
    assert_eq!(w.mc.subscribed().len(), 2);
    assert_eq!(prices(&w.engine)["targets"].as_array().unwrap().len(), 2);
}

#[test]
fn the_usage_page_filter_narrows_the_environments() {
    let w = World::new(&[("env-1", "", json!({})), ("env-2", "Build box", json!({}))]);
    Bridge::of(&w.engine).publish(&w.engine, "usage", json!({ "environmentId": "env-2" }));
    w.open();
    let targets = prices(&w.engine)["targets"].clone();
    assert_eq!(targets.as_array().unwrap().len(), 1);
    assert_eq!(targets[0]["id"], "env-2");
}
