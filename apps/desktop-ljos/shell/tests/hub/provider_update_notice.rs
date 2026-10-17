//! `providerUpdateNotice`: the toast that offers provider updates at launch,
//! what Update does, and how it is reported (ProviderUpdateNotice.cpp).

use std::path::PathBuf;

use hal_c2_shell::Launch;
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::McError;
use serde_json::json;

use crate::Hub;

const UPDATE: &str = "server.updateProvider";

fn config_dir(test: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join("hub-provider-update")
        .join(test);
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

fn hub(test: &str) -> Hub {
    Hub::with(Launch {
        config_dir: Some(config_dir(test)),
        ..Launch::default()
    })
}

fn behind(driver: &str, latest: &str) -> Json {
    json!({
        "instanceId": driver,
        "driver": driver,
        "enabled": true,
        "versionAdvisory": {
            "status": "behind_latest",
            "latestVersion": latest,
            "canUpdate": true,
            "updateCommand": format!("npm i -g {driver}"),
        },
    })
}

fn providers(hub: &Hub, providers: Json) {
    hub.mc.frame(
        &hub.engine,
        "config",
        "env-1",
        json!({"t": "config.providers", "providers": providers}),
    );
}

fn items(hub: &Hub) -> Vec<Json> {
    hub.published("toasts")["items"].as_array().unwrap().clone()
}

fn titles(hub: &Hub) -> Vec<String> {
    items(hub)
        .iter()
        .map(|i| i["title"].as_str().unwrap().to_owned())
        .collect()
}

fn press(hub: &Hub, id: &str, action: &str) {
    hub.dispatch("notification.action", json!({"id": id, "actionId": action}));
}

#[test]
fn one_outdated_provider_is_offered_in_a_toast_that_stays() {
    let hub = hub("offered");
    assert!(items(&hub).is_empty());
    providers(&hub, json!([behind("codex", "1.2.0")]));
    let toast = &items(&hub)[0];
    assert_eq!(toast["type"], "warning");
    assert_eq!(toast["title"], "Update Available: Codex v1.2.0");
    assert_eq!(
        toast["description"],
        "Install the update now or review provider settings."
    );
    // The lesser action first, as the Notifications brick lists them.
    assert_eq!(toast["actions"][0]["label"], "Settings");
    assert_eq!(toast["actions"][1]["label"], "Update");
    hub.advance(60_000);
    assert_eq!(items(&hub).len(), 1);
}

#[test]
fn the_same_versions_are_offered_once_and_other_versions_replace_the_prompt() {
    let hub = hub("once");
    providers(&hub, json!([behind("codex", "1.2.0")]));
    providers(&hub, json!([behind("codex", "1.2.0")]));
    assert_eq!(items(&hub).len(), 1);
    providers(
        &hub,
        json!([behind("codex", "1.3.0"), behind("claudeAgent", "2.0.0")]),
    );
    assert_eq!(titles(&hub), ["Updates Available: 2 providers"]);
    assert_eq!(items(&hub).len(), 1, "the old prompt is gone");
}

#[test]
fn a_provider_the_mc_cannot_update_gets_only_settings() {
    let hub = hub("manual");
    let mut provider = behind("cursor", "0.9.0");
    provider["versionAdvisory"]["canUpdate"] = json!(false);
    providers(&hub, json!([provider]));
    let toast = &items(&hub)[0];
    assert_eq!(
        toast["description"],
        "Cursor can be updated from provider settings."
    );
    assert_eq!(toast["actions"].as_array().unwrap().len(), 1);
    assert_eq!(toast["actions"][0]["label"], "Settings");
}

#[test]
fn disabled_broken_and_current_providers_are_not_offered() {
    let hub = hub("not-offered");
    let mut disabled = behind("codex", "1.2.0");
    disabled["enabled"] = json!(false);
    let mut broken = behind("grok", "1.0.0");
    broken["compatibilityAdvisory"] = json!({"latestVersionStatus": "broken"});
    let mut current = behind("pi", "1.0.0");
    current["versionAdvisory"]["status"] = json!("current");
    providers(&hub, json!([disabled, broken, current]));
    assert!(items(&hub).is_empty());
}

#[test]
fn closing_the_prompt_dismisses_those_versions_for_good() {
    let dir = config_dir("dismissed");
    let launch = || Launch {
        config_dir: Some(dir.clone()),
        ..Launch::default()
    };
    let first = Hub::with(launch());
    providers(&first, json!([behind("codex", "1.2.0")]));
    let id = items(&first)[0]["id"].as_str().unwrap().to_owned();
    first.dispatch("notification.dismiss", json!({"id": id}));
    assert_eq!(
        Settings::of(&first.engine).device_value("dismissedProviderUpdateNotificationKeys"),
        Some(json!(["codex:1.2.0"]))
    );

    // A later run of the shell does not offer them again, but newer ones.
    let second = Hub::with(launch());
    providers(&second, json!([behind("codex", "1.2.0")]));
    assert!(items(&second).is_empty());
    providers(&second, json!([behind("codex", "1.3.0")]));
    assert_eq!(titles(&second), ["Update Available: Codex v1.3.0"]);
}

#[test]
fn settings_opens_the_providers_section() {
    let hub = hub("settings");
    providers(&hub, json!([behind("codex", "1.2.0")]));
    let id = items(&hub)[0]["id"].as_str().unwrap().to_owned();
    press(&hub, &id, "secondary");
    let route = hub.published("route");
    assert_eq!(route["kind"], "settings");
    assert_eq!(route["section"], "/settings/providers");
}

#[test]
fn update_runs_the_command_and_reports_success() {
    let hub = hub("success");
    providers(&hub, json!([behind("codex", "1.2.0")]));
    let id = items(&hub)[0]["id"].as_str().unwrap().to_owned();
    press(&hub, &id, "primary");
    assert!(items(&hub).is_empty(), "the prompt is gone");
    assert_eq!(
        hub.mc.calls.borrow().last().unwrap().2,
        json!({"provider": "codex", "instanceId": "codex"})
    );
    let mut done = behind("codex", "1.2.0");
    done["updateState"] = json!({"status": "succeeded"});
    done["versionAdvisory"]["status"] = json!("current");
    hub.mc.answer(
        &hub.engine,
        UPDATE,
        Ok(json!({"providers": [done, behind("other", "9")]})),
    );
    let toast = &items(&hub)[0];
    assert_eq!(toast["type"], "success");
    assert_eq!(toast["title"], "Provider updated");
    assert_eq!(
        toast["description"],
        "New sessions will use the updated provider."
    );
    hub.advance(3_001);
    assert!(items(&hub).is_empty());
}

#[test]
fn update_waits_for_the_provider_to_finish_updating() {
    let hub = hub("waits");
    providers(&hub, json!([behind("codex", "1.2.0")]));
    let id = items(&hub)[0]["id"].as_str().unwrap().to_owned();
    press(&hub, &id, "primary");
    let mut running = behind("codex", "1.2.0");
    running["updateState"] = json!({"status": "running"});
    hub.mc
        .answer(&hub.engine, UPDATE, Ok(json!({"providers": [running]})));
    assert!(items(&hub).is_empty(), "nothing is reported while it runs");

    let mut failed = behind("codex", "1.2.0");
    failed["updateState"] = json!({"status": "failed", "message": "EACCES"});
    providers(&hub, json!([failed]));
    let toast = &items(&hub)[0];
    assert_eq!(toast["type"], "error");
    assert_eq!(toast["title"], "Provider update failed");
    assert_eq!(toast["description"], "EACCES");
    assert_eq!(toast["actions"][0]["label"], "Settings");
}

#[test]
fn a_refused_update_ends_the_run_and_says_why() {
    let hub = hub("refused");
    providers(
        &hub,
        json!([behind("codex", "1.2.0"), behind("claudeAgent", "2.0.0")]),
    );
    let id = items(&hub)[0]["id"].as_str().unwrap().to_owned();
    press(&hub, &id, "primary");
    // One after another: the second waits for the first.
    assert_eq!(hub.mc.methods().iter().filter(|m| *m == UPDATE).count(), 1);
    hub.mc.answer(
        &hub.engine,
        UPDATE,
        Err(McError {
            message: "no permission".into(),
            detail: Json::Null,
        }),
    );
    assert_eq!(hub.mc.methods().iter().filter(|m| *m == UPDATE).count(), 1);
    let toast = &items(&hub)[0];
    assert_eq!(toast["title"], "Provider updates failed");
    assert_eq!(toast["description"], "no permission");
}

#[test]
fn an_update_that_changed_nothing_is_reported_as_outdated() {
    let hub = hub("unchanged");
    providers(&hub, json!([behind("codex", "1.2.0")]));
    let id = items(&hub)[0]["id"].as_str().unwrap().to_owned();
    press(&hub, &id, "primary");
    let mut same = behind("codex", "1.2.0");
    same["updateState"] = json!({"status": "unchanged"});
    hub.mc
        .answer(&hub.engine, UPDATE, Ok(json!({"providers": [same]})));
    let toast = &items(&hub)[0];
    assert_eq!(toast["type"], "warning");
    assert_eq!(toast["title"], "Provider still needs an update");
    assert_eq!(
        toast["description"],
        "Codex still appears outdated. Check provider settings for details."
    );
}
