//! `deviceSettings`: Settings, Integrations, Devices
//! (DeviceSettingsController.cpp, features/settings/integrations.feature),
//! over the settings scope of a two-machine cluster.

use std::rc::Rc;

use hal_c2_shell::controllers::settings_scope::{Environment, SettingsScope};
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::McError;
use serde_json::json;

use crate::Hub;

const READ: &str = "hal-c2.readSettings";

fn page(hub: &Hub) -> Json {
    hub.published("deviceSettings")
}

fn count(hub: &Hub, method: &str) -> usize {
    hub.mc.methods().iter().filter(|m| *m == method).count()
}

/// "Laptop" (this MC's env-1) and "Build box" (env-2), both online, each with
/// the hub on or off as given.
fn cluster(laptop_hub: bool, build_box_hub: bool) -> Hub {
    let hub = Hub::new();
    hub.mc.set_ready(&hub.engine, true);
    SettingsScope::of(&hub.engine).set_sources(
        &hub.engine,
        Rc::new(|_| {
            vec![
                Environment {
                    id: "env-2".into(),
                    label: "Build box".into(),
                    online: true,
                },
                Environment {
                    id: "env-1".into(),
                    label: "Laptop".into(),
                    online: true,
                },
            ]
        }),
        Rc::new(|_| Vec::new()),
    );
    hub.dispatch("settings.navigate", json!({"to": "/settings/integrations"}));
    for (environment, on) in [("env-1", laptop_hub), ("env-2", build_box_hub)] {
        hub.mc.frame(
            &hub.engine,
            "config",
            environment,
            json!({"t": "config", "config": {"settings": {"enableDeviceSupport": on, "enableAgentDeviceAccess": false},
                "environment": {"capabilities": {}}}}),
        );
    }
    let own = hub
        .mc
        .pending_on("env-1", READ)
        .expect("the scope reads the laptop");
    hub.mc.reply(
        &hub.engine,
        own,
        Ok(json!({"settings": {"enableDeviceSupport": laptop_hub, "enableAgentDeviceAccess": false}, "version": 1})),
    );
    hub
}

fn devices(hub: &Hub, state: Json) {
    hub.mc.frame(
        &hub.engine,
        "devices",
        "",
        json!({"t": "devices", "state": state}),
    );
}

fn ready_state() -> Json {
    json!({
        "hostStatus": "ready",
        "supportsToolUpdate": true,
        "supportsToolInspection": true,
        "supportsHostRetry": true,
        "devices": [{"platform": "android"}],
        "hosts": [{"id": "h1", "kind": "local", "label": "This computer",
            "platforms": [{"platform": "ios", "available": false, "reason": "Xcode is not installed."}, {"platform": "android", "available": true}],
            "tools": {
                "hub": {"runningVersion": "1.2.0", "requiredVersion": "1.2.0", "installedVersions": ["1.2.0"]},
                "agent": {"requiredVersion": "2.0.0", "installedVersions": ["1.9.0"]},
            }}],
    })
}

#[test]
fn the_page_follows_the_devices_of_the_first_environment_only_while_it_shows() {
    let hub = cluster(true, false);
    let followed = |hub: &Hub| {
        hub.mc
            .subscriptions()
            .into_iter()
            .filter(|(_, s)| s["type"] == "devices")
            .count()
    };
    assert_eq!(followed(&hub), 1);
    assert_eq!(page(&hub)["loaded"], false);
    assert_eq!(
        page(&hub)["hub"]["enabled"],
        false,
        "nothing can be switched before the status lands"
    );
    assert_eq!(
        page(&hub)["statusNote"],
        "Status for Laptop. Select an environment to inspect its simulator support."
    );

    devices(&hub, ready_state());
    let state = page(&hub);
    assert_eq!(state["loaded"], true);
    assert_eq!(state["hub"]["mixed"], true, "one machine has it on");
    assert_eq!(state["hub"]["enabled"], true);
    assert_eq!(state["hub"]["version"], "v1.2.0");
    assert_eq!(state["hub"]["update"], "");
    assert_eq!(state["agent"]["version"], "v1.9.0");
    assert_eq!(state["agent"]["update"], "Update to v2.0.0");
    assert_eq!(state["canCheck"], true);

    hub.dispatch("settings.navigate", json!({"to": "/settings/general"}));
    assert_eq!(page(&hub), json!({"open": false}));
    assert_eq!(followed(&hub), 0);
}

#[test]
fn the_platforms_show_once_the_hub_is_ready_and_say_what_is_missing() {
    let hub = cluster(true, true);
    devices(&hub, ready_state());
    let platforms = page(&hub)["platforms"].clone();
    assert_eq!(
        platforms[0],
        json!({"platform": "iOS", "ready": false, "message": "Xcode is not installed."})
    );
    assert_eq!(
        platforms[1],
        json!({"platform": "Android", "ready": true, "message": "The Android SDK and Emulator are available."})
    );

    let mut empty = ready_state();
    empty["devices"] = json!([]);
    devices(&hub, empty);
    assert_eq!(
        page(&hub)["platforms"][1]["message"],
        "The Android SDK is installed, but no virtual device exists. Create one in Android Studio → Device Manager."
    );
}

#[test]
fn turning_the_hub_on_configures_every_environment_and_frees_the_switches_after_the_last() {
    let hub = cluster(false, false);
    devices(&hub, ready_state());
    hub.dispatch("deviceSettings.hub", json!({"enabled": true}));
    assert_eq!(page(&hub)["pending"], "hub");
    assert_eq!(page(&hub)["hub"]["enabled"], false);
    for environment in ["env-1", "env-2"] {
        let index = hub.mc.pending_on(environment, "device.configure").unwrap();
        assert_eq!(
            hub.mc.calls.borrow()[index].2,
            json!({"enabled": true, "onboardingCompleted": true})
        );
    }
    // Nothing else is taken while it works.
    hub.dispatch("deviceSettings.agent", json!({"enabled": true}));
    assert_eq!(count(&hub, "device.configure"), 2);

    // The progress is the host's own status, as the devices shape tells it.
    assert_eq!(page(&hub)["hub"]["status"], "Updating…");
    let mut installing = ready_state();
    installing["hostStatus"] = json!("installing");
    devices(&hub, installing);
    hub.mc
        .answer_on(&hub.engine, "env-1", "device.configure", Ok(json!({})));
    assert_eq!(page(&hub)["pending"], "hub");
    assert_eq!(page(&hub)["hub"]["status"], "Installing…");
    assert_eq!(page(&hub)["busy"], true);
    hub.mc
        .answer_on(&hub.engine, "env-2", "device.configure", Ok(json!({})));
    assert_eq!(page(&hub)["pending"], "");
}

#[test]
fn turning_the_hub_off_turns_agent_access_off_and_a_failure_names_the_machine() {
    let hub = cluster(true, true);
    devices(&hub, ready_state());
    hub.dispatch("deviceSettings.hub", json!({"enabled": false}));
    let index = hub.mc.pending_on("env-2", "device.configure").unwrap();
    assert_eq!(
        hub.mc.calls.borrow()[index].2,
        json!({"enabled": false, "agentAccessEnabled": false})
    );
    hub.mc
        .answer_on(&hub.engine, "env-1", "device.configure", Ok(ready_state()));
    hub.mc.answer_on(
        &hub.engine,
        "env-2",
        "device.configure",
        Err(McError::new("offline")),
    );
    assert_eq!(page(&hub)["pending"], "");
    let toast = hub.published("toasts")["items"][0].clone();
    assert_eq!(
        toast["title"],
        "Device settings not saved on all environments"
    );
    assert_eq!(toast["description"], "Could not update Build box.");
}

#[test]
fn checking_updating_and_retrying_read_the_devices_and_a_failed_update_is_said() {
    let hub = cluster(true, true);
    devices(&hub, ready_state());
    let last = |hub: &Hub| {
        hub.mc
            .calls
            .borrow()
            .iter()
            .rev()
            .find(|(_, m, _)| m == "device.list")
            .cloned()
            .unwrap()
    };

    hub.dispatch("deviceSettings.check", json!({}));
    assert_eq!(last(&hub).2, json!({"inspectOnly": true}));
    assert_eq!(page(&hub)["pending"], "check");
    hub.mc.answer(&hub.engine, "device.list", Ok(ready_state()));
    assert_eq!(page(&hub)["pending"], "");

    hub.dispatch("deviceSettings.update", json!({"tool": "nonsense"}));
    assert_eq!(count(&hub, "device.list"), 1);
    hub.dispatch("deviceSettings.update", json!({"tool": "agent"}));
    assert_eq!(last(&hub).2, json!({"updateTool": "agent"}));
    assert_eq!(page(&hub)["pending"], "update-agent");
    hub.mc
        .answer(&hub.engine, "device.list", Err(McError::new("no network")));
    assert_eq!(
        page(&hub)["updateError"],
        json!({"tool": "agent", "message": "Update failed. Check this host's network connection and try again."})
    );

    let mut failed = ready_state();
    failed["hostStatuses"] = json!({"h1": {"status": "failed", "detail": "Port in use."}});
    devices(&hub, failed);
    assert_eq!(
        page(&hub)["hosts"],
        json!([{"id": "h1", "label": "This computer", "failed": true, "message": "Port in use.", "canRetry": true}])
    );
    hub.dispatch("deviceSettings.retry", json!({"hostId": "h1"}));
    assert_eq!(last(&hub).2, json!({"retryHostId": "h1"}));
}

#[test]
fn nothing_is_taken_while_the_page_is_closed() {
    let hub = Hub::new();
    hub.dispatch("deviceSettings.hub", json!({"enabled": true}));
    assert_eq!(count(&hub, "device.configure"), 0);
    assert_eq!(page(&hub), json!({"open": false}));
}
