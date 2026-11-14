//! Settings → General, Background activity (`backgroundActivity`).

use serde_json::json;

use crate::page::{accept_write, hub_with, open, written};

#[test]
fn the_profile_shows_and_advanced_starts_from_the_one_it_was_on() {
    let hub = hub_with(json!({"settings": {}}));
    // Closed until the page shows.
    assert_eq!(hub.published("backgroundActivity"), json!({"open": false}));
    open(&hub, "/settings/general");
    let state = hub.published("backgroundActivity");
    assert_eq!(state["profile"], "balanced");
    assert_eq!(state["advanced"], false);
    assert_eq!(state["fetchSeconds"], 30);
    assert_eq!(state["pauseWhenLocked"], true);
    assert_eq!(state["profiles"].as_array().unwrap().len(), 4);

    hub.dispatch(
        "backgroundActivity.profile",
        json!({"value": "battery-saver"}),
    );
    assert_eq!(
        written(&hub)["backgroundActivity"],
        json!({"schemaVersion": 1, "profile": "battery-saver", "overrides": {}})
    );
    accept_write(&hub, 2);

    hub.dispatch("backgroundActivity.profile", json!({"value": "custom"}));
    let custom = written(&hub)["backgroundActivity"].clone();
    assert_eq!(custom["profile"], "custom");
    assert_eq!(custom["baseProfile"], "battery-saver");
    assert_eq!(custom["overrides"], json!({}));
}

#[test]
fn an_advanced_profile_keeps_its_overrides() {
    let hub = hub_with(json!({"settings": {"backgroundActivity": {
        "schemaVersion": 1, "profile": "custom", "baseProfile": "performance",
        "overrides": {"automaticGitFetchInterval": 45000},
    }}}));
    open(&hub, "/settings/general");
    let state = hub.published("backgroundActivity");
    assert_eq!(state["advanced"], true);
    assert_eq!(state["fetchSeconds"], 45);

    hub.dispatch("backgroundActivity.set", json!({"pauseWhenLocked": false}));
    let activity = written(&hub)["backgroundActivity"].clone();
    assert_eq!(activity["baseProfile"], "performance");
    assert_eq!(
        activity["overrides"],
        json!({"automaticGitFetchInterval": 45000, "pauseWhenHostLocked": false})
    );
    // Seconds are clamped to a day.
    accept_write(&hub, 2);
    hub.dispatch("backgroundActivity.set", json!({"fetchSeconds": 999999}));
    assert_eq!(
        written(&hub)["backgroundActivity"]["overrides"]["automaticGitFetchInterval"],
        86_400_000
    );
}

#[test]
fn an_unknown_profile_is_not_written() {
    let hub = hub_with(json!({"settings": {}}));
    open(&hub, "/settings/general");
    hub.dispatch("backgroundActivity.profile", json!({"value": "turbo"}));
    assert_eq!(crate::page::writes(&hub), 0);
}
