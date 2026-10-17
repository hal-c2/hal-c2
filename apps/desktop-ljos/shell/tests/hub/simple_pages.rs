//! The small settings pages: text generation, storage, load balancing, the
//! folder explorer's switch and the build's stage.

use hal_c2_shell::Launch;
use hal_c2_shell::commands::Commands;
use hal_c2_shell::controllers::settings::Settings;
use serde_json::json;

use crate::Hub;
use crate::page::{accept_write, hub_with, open, reject_write, toasts, writes, written};

fn providers() -> serde_json::Value {
    json!([
        {"instanceId": "codex", "displayName": "Codex", "enabled": true, "installed": true,
         "models": [{"slug": "gpt-5", "name": "GPT-5"}, {"slug": "old", "isLegacy": true}]},
        {"instanceId": "claude", "displayName": "Claude", "enabled": true, "installed": true,
         "models": [{"slug": "sonnet", "name": "Sonnet"}]},
        {"instanceId": "off", "displayName": "Off", "enabled": false, "installed": true,
         "models": [{"slug": "x"}]},
    ])
}

// -- Text generation ------------------------------------------------------

#[test]
fn the_text_generation_model_lists_what_can_write_and_saves_a_choice() {
    let hub = hub_with(json!({"settings": {}, "providers": providers()}));
    open(&hub, "/settings/general");
    let state = hub.published("textGeneration");
    assert_eq!(state["label"], "Default");
    assert_eq!(state["resettable"], false);
    assert_eq!(state["unavailable"], "");
    assert_eq!(
        state["models"],
        json!([
            {"key": "codex:gpt-5", "label": "Codex · GPT-5"},
            {"key": "claude:sonnet", "label": "Claude · Sonnet"},
        ])
    );

    hub.dispatch("textGeneration.choose", json!({"key": "claude:sonnet"}));
    assert_eq!(
        written(&hub)["textGenerationModelSelection"],
        json!({"instanceId": "claude", "model": "sonnet"})
    );
    accept_write(&hub, 2);
    let state = hub.published("textGeneration");
    assert_eq!(state["value"], "claude:sonnet");
    assert_eq!(state["label"], "Claude · Sonnet");
    assert_eq!(state["resettable"], true);

    hub.dispatch("textGeneration.reset", json!({}));
    assert!(written(&hub).get("textGenerationModelSelection").is_none());
}

#[test]
fn a_model_the_environment_does_not_offer_is_refused_with_a_toast() {
    let hub = hub_with(json!({"settings": {}, "providers": providers()}));
    open(&hub, "/settings/general");
    hub.dispatch("textGeneration.choose", json!({"key": "off:x"}));
    assert_eq!(writes(&hub), 0);
    let shown = toasts(&hub);
    assert_eq!(shown.len(), 1);
    assert_eq!(shown[0].0, "Text generation model not saved");
    assert!(shown[0].1.starts_with("This model is unavailable on"));
}

#[test]
fn a_saved_model_no_provider_offers_still_names_itself() {
    let hub = hub_with(json!({"settings": {
        "textGenerationModelSelection": {"instanceId": "gone", "model": "m"}},
        "providers": providers()}));
    open(&hub, "/settings/general");
    assert_eq!(
        hub.published("textGeneration")["label"],
        "gone:m (Unavailable)"
    );
}

// -- Storage --------------------------------------------------------------

#[test]
fn storage_rules_show_by_capability_and_save_into_the_document() {
    let hub = hub_with(json!({"settings": {}}));
    open(&hub, "/settings/storage");
    // The environment does not say it can clean up yet.
    let state = hub.published("storageSettings");
    assert_eq!(state["status"], "unsupported");
    assert_eq!(state["eligible"], json!([]));

    let hub = hub_with(json!({
        "settings": {"storageCleanup": {"logsAfterDays": 7}},
        "environment": {"capabilities": {"storageCleanup": true}},
    }));
    open(&hub, "/settings/storage");
    let state = hub.published("storageSettings");
    assert_eq!(state["status"], "ready");
    assert_eq!(state["mode"]["value"], "inherit");
    let artifact = |key: &str| {
        state["artifacts"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["key"] == key)
            .cloned()
            .unwrap()
    };
    assert_eq!(artifact("logsAfterDays")["value"], 7);
    assert_eq!(artifact("browserArtifactsAfterDays")["value"], json!(null));
    assert_eq!(state["worktrees"].as_array().unwrap().len(), 4);

    // Days are rounded and kept within a range; a switch is a flag.
    hub.dispatch(
        "storageSettings.set",
        json!({"key": "browserArtifactsAfterDays", "value": 99999}),
    );
    assert_eq!(
        written(&hub)["storageCleanup"],
        json!({"logsAfterDays": 7, "browserArtifactsAfterDays": 3650})
    );
    accept_write(&hub, 2);
    hub.dispatch(
        "storageSettings.set",
        json!({"key": "worktreeOnMerge", "value": true}),
    );
    assert_eq!(written(&hub)["storageCleanup"]["worktreeOnMerge"], true);
    // Unknown rules are not written, and the mode belongs to a project.
    let before = writes(&hub);
    hub.dispatch("storageSettings.set", json!({"key": "nope", "value": 1}));
    hub.dispatch("storageSettings.mode", json!({"mode": "off"}));
    assert_eq!(writes(&hub), before);
}

// -- Load balancing -------------------------------------------------------

fn cluster_hub() -> (Hub, tempfile::TempDir) {
    let dir = tempfile::tempdir().unwrap();
    let hub = Hub::with(Launch {
        mc_origin: Some("http://127.0.0.1:3773".into()),
        cache_dir: Some(dir.path().to_owned()),
        config_dir: Some(dir.path().join("config")),
        ..Launch::default()
    });
    hub.mc.set_ready(&hub.engine, true);
    (hub, dir)
}

fn shell_frame(machines: &[(&str, &str, &str)]) -> serde_json::Value {
    let mcs: Vec<_> = machines
        .iter()
        .map(|(mc, environment, label)| {
            json!({"mc": mc,
                   "environment": {"environmentId": environment, "label": label,
                                    "serverVersion": "0.0.23-nightly.20260101.4",
                                    "capabilities": {}},
                   "online": true, "epoch": "e1", "rev": 1})
        })
        .collect();
    json!({"t": "shell", "mcs": mcs, "rows": []})
}

#[test]
fn load_balancing_waits_for_a_second_machine_and_saves_weights() {
    let (hub, _dir) = cluster_hub();
    // The controllers start with the first snapshot of the cluster.
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        shell_frame(&[("mc-1", "env-1", "Laptop")]),
    );
    crate::page::send_config(&hub, json!({"settings": {}}), 1);
    assert_eq!(hub.published("loadBalancing"), serde_json::Value::Null);

    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        shell_frame(&[("mc-1", "env-1", "Laptop"), ("mc-2", "env-2", "Build box")]),
    );
    let state = hub.published("loadBalancing");
    assert_eq!(state["enabled"], false);
    assert_eq!(state["summary"], "Off");
    assert_eq!(state["machines"][0]["environmentId"], "env-1");
    assert_eq!(state["machines"][1]["environmentId"], "env-2");
    assert_eq!(state["machines"][1]["weight"], 50);

    hub.dispatch("loadBalancing.enable", json!({"enabled": true}));
    assert_eq!(written(&hub)["loadBalancingEnabled"], true);
    accept_write(&hub, 2);
    hub.dispatch(
        "loadBalancing.prefer",
        json!({"environmentId": "env-2", "weight": 25}),
    );
    assert_eq!(written(&hub)["loadBalancingWeights"], json!({"env-2": 25}));
    accept_write(&hub, 3);
    let state = hub.published("loadBalancing");
    // The cluster's labels come with SettingsScope::set_sources (a
    // TODO(port)), so a machine is named by its id until then.
    assert_eq!(state["summary"], "env-2 less often");
    assert_eq!(state["machines"][1]["weight"], 25);

    // A weight that is not offered is ignored.
    let before = writes(&hub);
    hub.dispatch(
        "loadBalancing.prefer",
        json!({"environmentId": "env-2", "weight": 7}),
    );
    assert_eq!(writes(&hub), before);
}

#[test]
fn a_load_balancing_save_that_fails_says_so() {
    let (hub, _dir) = cluster_hub();
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        shell_frame(&[("mc-1", "env-1", "Laptop")]),
    );
    crate::page::send_config(&hub, json!({"settings": {}}), 1);
    hub.dispatch("loadBalancing.enable", json!({"enabled": true}));
    reject_write(&hub, "no space");
    assert!(
        toasts(&hub)
            .iter()
            .any(|(title, description)| title == "Setting not saved"
                && description.contains("no space")),
        "{:?}",
        toasts(&hub)
    );
}

// -- Folders and stage ----------------------------------------------------

#[test]
fn the_folder_explorer_toggles_by_action_and_by_command() {
    let hub = Hub::new();
    assert_eq!(hub.published("folders"), json!({"open": false}));
    hub.dispatch("folders.toggle", json!({}));
    assert_eq!(hub.published("folders"), json!({"open": true}));
    hub.dispatch("folders.toggle", json!({"open": true}));
    assert_eq!(hub.published("folders"), json!({"open": true}));
    assert!(Commands::of(&hub.engine).run(&hub.engine, "folders.toggle"));
    assert_eq!(hub.published("folders"), json!({"open": false}));
}

#[test]
fn a_nightly_mc_marks_the_stage_as_the_identification_mode_chooses() {
    let (hub, _dir) = cluster_hub();
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        shell_frame(&[("mc-1", "env-1", "Laptop")]),
    );
    let stage = hub.published("stage");
    assert_eq!(stage["label"], "Nightly");
    assert!(stage["pill"].is_null());
    Settings::of(&hub.engine).write_device(
        &hub.engine,
        "environmentIdentificationMode",
        json!("pill"),
    );
    assert_eq!(hub.published("stage")["pill"], "Nightly");
    Settings::of(&hub.engine).write_device(
        &hub.engine,
        "environmentIdentificationMode",
        json!("artwork"),
    );
    let stage = hub.published("stage");
    assert_eq!(stage["artwork"], "nightly");
    assert!(stage["pill"].is_null());
}
