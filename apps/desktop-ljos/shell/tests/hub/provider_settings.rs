//! Settings → Providers (`providerSettings`, ProviderSettingsController.cpp,
//! features/settings/providers-panel.feature and
//! features/providers/provider-setup.feature): one environment's providers in
//! a cluster, their sign-in, versions and instances, the add-provider wizard
//! and the ACP Registry.

use std::rc::Rc;

use hal_c2_shell::Launch;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::SubId;
use hal_c2_shell::provider::{drivers, instances};
use ljos::prelude::{Platform, RecordedUrls};
use proptest::prelude::*;
use serde_json::json;

use crate::Hub;
use crate::page::{
    READ, WRITE, accept_write, answer, count, failure, last, open, reject_write, send_config,
    settle, toasts, writes, written,
};

const SECTION: &str = "/settings/providers";

fn page(hub: &Hub) -> Json {
    hub.published("providerSettings")
}

fn card(hub: &Hub, instance_id: &str) -> Json {
    page(hub)["providers"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|p| p["instanceId"] == instance_id)
        .cloned()
        .unwrap_or_else(|| panic!("no card for {instance_id}"))
}

/// A provider as the environment's `config` lists it: installed, enabled
/// and signed out, signing in from HAL-C2.
fn provider(instance_id: &str, driver: &str) -> Json {
    json!({
        "instanceId": instance_id,
        "driver": driver,
        "enabled": true,
        "installed": true,
        "status": "ready",
        "version": "1.2.3",
        "auth": {"status": "unauthenticated"},
        "setup": {"canAuthenticate": true},
        "models": [
            {"slug": "fast-one", "name": "Fast one"},
            {"slug": "big-one", "name": "Big one"},
        ],
    })
}

/// "Laptop" (this MC's env-1) and "Desk" (env-2, online or not) in a
/// cluster, the Providers section open on Laptop with `providers` listed
/// over `settings`.
fn opened(settings: Json, providers: Vec<Json>, desk_online: bool) -> (Hub, tempfile::TempDir) {
    let dir = tempfile::tempdir().unwrap();
    let hub = Hub::with(Launch {
        mc_origin: Some("http://127.0.0.1:3773".into()),
        cache_dir: Some(dir.path().join("cache")),
        config_dir: Some(dir.path().join("config")),
        ..Launch::default()
    });
    hub.mc.set_ready(&hub.engine, true);
    send_config(
        &hub,
        json!({"settings": settings, "providers": providers}),
        1,
    );
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell",
               "mcs": [{"mc": "mc-1",
                        "environment": {"environmentId": "env-1", "label": "Laptop", "capabilities": {}},
                        "online": true, "epoch": "e1", "rev": 1},
                       {"mc": "mc-2",
                        "environment": {"environmentId": "env-2", "label": "Desk", "capabilities": {}},
                        "online": desk_online, "epoch": "e2", "rev": 1}],
               "rows": [["mc-1", "p1", "project",
                         {"id": "p1", "title": "Ljos", "workspaceRoot": "/w/ljos"}]]}),
    );
    open(&hub, SECTION);
    (hub, dir)
}

fn codex_and_claude() -> (Hub, tempfile::TempDir) {
    opened(
        json!({}),
        vec![
            provider("codex", "codex"),
            provider("claudeAgent", "claudeAgent"),
        ],
        true,
    )
}

/// The shape followed for `kind` (`providerAuth`, `providerInstall`) of an
/// instance.
fn shape(hub: &Hub, kind: &str, instance_id: &str) -> Option<(SubId, Json)> {
    hub.mc
        .subscriptions()
        .into_iter()
        .find(|(_, s)| s["type"] == kind && s["instanceId"] == instance_id)
}

/// The environment says where an instance's sign-in stands.
fn auth(hub: &Hub, instance_id: &str, state: Json) {
    let (id, _) = shape(hub, "providerAuth", instance_id).expect("its sign-in is followed");
    hub.mc.frame_to(
        &hub.engine,
        id,
        json!({"t": "providerAuth", "state": state}),
    );
}

fn install(hub: &Hub, instance_id: &str, state: Json) {
    let (id, _) = shape(hub, "providerInstall", instance_id).expect("its runtime is followed");
    hub.mc.frame_to(
        &hub.engine,
        id,
        json!({"t": "providerInstall", "state": state}),
    );
}

fn signed_out(instance_id: &str) -> Json {
    json!({"instanceId": instance_id, "phase": "idle", "methods": [{"id": "browser"}]})
}

fn browser_flow(instance_id: &str) -> Json {
    json!({"instanceId": instance_id, "phase": "waiting", "flowId": "flow-1",
           "methods": [{"id": "browser"}],
           "interaction": {"id": "browser-1", "type": "browser",
                           "url": "https://auth.example/codex", "acceptsCallback": true}})
}

fn terminal_flow(instance_id: &str) -> Json {
    json!({"instanceId": instance_id, "phase": "waiting", "flowId": "flow-1",
           "interaction": {"id": "term-1", "type": "terminal", "output": "Paste the code: "}})
}

/// Answers the confirmation showing.
fn confirm(hub: &Hub, title: &str, accepted: bool) {
    let question = hub.published("confirmation");
    assert_eq!(question["title"], title);
    hub.dispatch(
        "confirmation.answer",
        json!({"requestId": question["requestId"], "accepted": accepted}),
    );
}

fn pending_respond(hub: &Hub) -> usize {
    let calls = hub.mc.calls.borrow().len();
    (0..calls)
        .filter(|&i| hub.mc.calls.borrow()[i].1 == "provider.auth.respond" && hub.mc.is_pending(i))
        .count()
}

// ---- Environments ----------------------------------------------------------

#[test]
fn the_environments_providers_are_listed_this_machine_first() {
    let (hub, _dir) = codex_and_claude();
    let state = page(&hub);
    assert_eq!(state["open"], true);
    assert_eq!(state["status"], "ready");
    assert_eq!(state["environmentId"], "env-1");
    let environments: Vec<_> = state["environments"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| (e["label"].clone(), e["local"].clone()))
        .collect();
    assert_eq!(
        environments,
        [
            (json!("Laptop"), json!(true)),
            (json!("Desk"), json!(false))
        ]
    );
    let codex = card(&hub, "codex");
    assert_eq!(codex["name"], "Codex");
    assert_eq!(codex["version"], "v1.2.3");
    assert_eq!(codex["headline"], "Not authenticated");
    assert_eq!(codex["modelSummary"], "2 models");
    assert_eq!(codex["custom"], false);
    assert_eq!(card(&hub, "claudeAgent")["name"], "Claude");
    // Each provider that signs in from HAL-C2 has its sign-in followed on the
    // MC serving the environment.
    let (_, followed) = shape(&hub, "providerAuth", "codex").unwrap();
    assert_eq!(followed["mc"], "mc-1");
}

#[test]
fn a_disconnected_environment_asks_to_reconnect_and_lists_once_back() {
    let (hub, _dir) = opened(json!({}), vec![provider("codex", "codex")], false);
    hub.dispatch("providerSettings.environment", json!({"id": "env-2"}));
    let state = page(&hub);
    assert_eq!(state["status"], "offline");
    assert_eq!(
        state["description"],
        "Reconnect this device to set up its provider, or select another device."
    );
    assert_eq!(state["providers"], json!([]));

    hub.dispatch("providerSettings.environment", json!({"id": "env-1"}));
    assert_eq!(page(&hub)["status"], "loading");
    // Followed again, the environment says its config again.
    send_config(
        &hub,
        json!({"settings": {}, "providers": [provider("codex", "codex")]}),
        1,
    );
    assert_eq!(page(&hub)["status"], "ready");
    assert_eq!(page(&hub)["providers"].as_array().unwrap().len(), 1);
}

#[test]
fn nothing_is_followed_once_the_section_is_left() {
    let (hub, _dir) = codex_and_claude();
    assert!(shape(&hub, "providerAuth", "codex").is_some());
    hub.dispatch("settings.navigate", json!({"to": "/settings/cluster"}));
    assert_eq!(page(&hub)["open"], false);
    assert!(shape(&hub, "providerAuth", "codex").is_none());
    assert!(shape(&hub, "providerAuth", "claudeAgent").is_none());
    assert_eq!(page(&hub)["providers"], json!([]));
}

#[test]
fn the_panel_says_when_providers_were_last_checked() {
    let mut codex = provider("codex", "codex");
    codex["checkedAt"] = json!("2026-10-17T10:00:00.000Z");
    let mut claude = provider("claudeAgent", "claudeAgent");
    claude["checkedAt"] = json!("2026-10-17T10:05:00Z");
    let (hub, _dir) = opened(json!({}), vec![codex, claude], true);
    assert_eq!(page(&hub)["checkedAt"], "2026-10-17T10:05:00.000Z");

    hub.dispatch("providerSettings.refresh", json!({}));
    assert_eq!(page(&hub)["refreshing"], true);
    assert_eq!(
        last(&hub, "env-1", "server.refreshProviders"),
        json!({"refreshModels": true})
    );
    answer(
        &hub,
        "env-1",
        "server.refreshProviders",
        Err(failure("Timed out")),
    );
    assert_eq!(page(&hub)["refreshing"], false);
    assert!(toasts(&hub).contains(&("Could not refresh providers".into(), "Timed out".into())));
}

// ---- Enabling --------------------------------------------------------------

#[test]
fn turning_a_built_in_off_and_on_saves_its_providers_entry() {
    let (hub, _dir) = codex_and_claude();
    hub.dispatch(
        "providerSettings.enable",
        json!({"instanceId": "codex", "enabled": false}),
    );
    assert_eq!(
        written(&hub)["providers"]["codex"],
        json!({"enabled": false})
    );
    accept_write(&hub, 2);

    hub.dispatch(
        "providerSettings.enable",
        json!({"instanceId": "codex", "enabled": true}),
    );
    assert_eq!(
        written(&hub)["providers"]["codex"],
        json!({"enabled": true})
    );
}

#[test]
fn a_failed_save_says_the_provider_settings_could_not_be_saved() {
    let (hub, _dir) = codex_and_claude();
    hub.dispatch(
        "providerSettings.enable",
        json!({"instanceId": "codex", "enabled": false}),
    );
    reject_write(&hub, "Disk full");
    assert!(toasts(&hub).contains(&(
        "Could not save provider settings".into(),
        "Disk full".into()
    )));
    assert_eq!(card(&hub, "codex")["enabled"], true);
}

// ---- The wizard ------------------------------------------------------------

#[test]
fn the_wizard_adds_an_instance_named_after_its_label() {
    let (hub, _dir) = codex_and_claude();
    hub.dispatch("providerSettings.wizardOpen", json!({}));
    // It lists the registry's agents as it opens.
    assert_eq!(
        last(&hub, "env-1", "server.searchAcpRegistry"),
        json!({"query": ""})
    );
    let wizard = &page(&hub)["wizard"];
    assert_eq!(wizard["steps"], json!(["Provider", "Identity", "Config"]));
    assert_eq!(wizard["driver"], "codex");
    assert!(
        !wizard["drivers"]
            .as_array()
            .unwrap()
            .iter()
            .any(|d| d["id"] == "acpRegistry")
    );

    hub.dispatch(
        "providerSettings.wizardDriver",
        json!({"driver": "claudeAgent"}),
    );
    hub.dispatch("providerSettings.wizardLabel", json!({"label": "Work"}));
    hub.dispatch("providerSettings.wizardStep", json!({"step": 2}));
    let wizard = &page(&hub)["wizard"];
    assert_eq!(wizard["step"], 2);
    assert_eq!(wizard["instanceId"], "claudeAgent_work");
    hub.dispatch(
        "providerSettings.wizardField",
        json!({"key": "homePath", "value": " ~/.claude-work "}),
    );
    hub.dispatch("providerSettings.wizardAccent", json!({"color": "#22AA44"}));
    hub.dispatch("providerSettings.wizardSubmit", json!({}));
    assert_eq!(page(&hub)["wizard"]["saving"], true);
    assert_eq!(
        written(&hub)["providerInstances"]["claudeAgent_work"],
        json!({"driver": "claudeAgent", "enabled": true, "displayName": "Work",
               "accentColor": "#22aa44", "config": {"homePath": "~/.claude-work"}})
    );
    accept_write(&hub, 2);
    assert_eq!(page(&hub)["wizard"], Json::Null);
    assert!(toasts(&hub).contains(&(
        "Provider instance added".into(),
        "Claude instance 'claudeAgent_work' was added.".into()
    )));
    // Until the environment lists it, it shows as being checked.
    let added = card(&hub, "claudeAgent_work");
    assert_eq!(added["pending"], true);
    assert_eq!(added["headline"], "Checking provider status");
    assert_eq!(added["custom"], true);
    assert_eq!(added["accentColor"], "#22aa44");
}

#[test]
fn a_taken_instance_id_keeps_the_wizard_on_identity() {
    let (hub, _dir) = codex_and_claude();
    hub.dispatch("providerSettings.wizardOpen", json!({}));
    hub.dispatch(
        "providerSettings.wizardStep",
        json!({"step": 2, "instanceId": "claudeAgent"}),
    );
    let wizard = &page(&hub)["wizard"];
    assert_eq!(wizard["step"], 1);
    assert_eq!(
        wizard["instanceIdError"],
        "An instance named 'claudeAgent' already exists."
    );
    hub.dispatch("providerSettings.wizardSubmit", json!({}));
    assert_eq!(page(&hub)["wizard"]["step"], 1);
    assert_eq!(writes(&hub), 0);
    // Going back always works, and keeps what was chosen.
    hub.dispatch("providerSettings.wizardStep", json!({"step": 0}));
    let wizard = &page(&hub)["wizard"];
    assert_eq!(wizard["step"], 0);
    assert_eq!(wizard["instanceId"], "claudeAgent");
}

#[test]
fn a_wizard_that_cannot_save_stays_open() {
    let (hub, _dir) = codex_and_claude();
    hub.dispatch("providerSettings.wizardOpen", json!({}));
    hub.dispatch("providerSettings.wizardLabel", json!({"label": "Personal"}));
    hub.dispatch("providerSettings.wizardSubmit", json!({}));
    // While it saves nothing in it changes.
    hub.dispatch("providerSettings.wizardLabel", json!({"label": "Other"}));
    reject_write(&hub, "Refused");
    let wizard = &page(&hub)["wizard"];
    assert_eq!(wizard["saving"], false);
    assert_eq!(wizard["label"], "Personal");
    assert!(toasts(&hub).contains(&("Could not add provider instance".into(), "Refused".into())));
}

// ---- The ACP Registry ------------------------------------------------------

fn registry_agents() -> Json {
    json!({"agents": [
        {"id": "gemini-cli", "name": "Gemini CLI", "description": "Google's Gemini agent",
         "distribution": "npx", "website": "https://geminicli.com",
         "icon": "https://cdn.agentclientprotocol.com/gemini-cli.svg"},
        {"id": "goose", "name": "Goose", "distribution": "binary",
         "repository": "https://github.com/block/goose", "icon": "https://evil.example/goose.svg"},
    ]})
}

#[test]
fn an_agent_from_the_registry_is_prepared_then_named() {
    let (hub, _dir) = codex_and_claude();
    let opened_urls = RecordedUrls::default();
    Platform::of(&hub.engine).set_open_url(Rc::new(opened_urls.clone()));
    hub.dispatch("providerSettings.wizardOpen", json!({}));
    assert_eq!(page(&hub)["wizard"]["registry"]["searching"], true);
    answer(
        &hub,
        "env-1",
        "server.searchAcpRegistry",
        Ok(registry_agents()),
    );
    let registry = &page(&hub)["wizard"]["registry"];
    assert_eq!(registry["searching"], false);
    let agents = registry["agents"].as_array().unwrap();
    assert_eq!(
        agents[0]["iconUrl"],
        "https://cdn.agentclientprotocol.com/gemini-cli.svg"
    );
    assert_eq!(agents[1]["iconUrl"], "");
    assert_eq!(agents[1]["website"], "https://github.com/block/goose");
    assert_eq!(agents[1]["progress"], "Downloading");

    hub.dispatch(
        "providerSettings.registryAbout",
        json!({"agentId": "goose"}),
    );
    assert_eq!(opened_urls.urls(), ["https://github.com/block/goose"]);

    hub.dispatch(
        "providerSettings.registryAdd",
        json!({"agentId": "gemini-cli"}),
    );
    assert_eq!(page(&hub)["wizard"]["registry"]["busy"], true);
    // A search while it prepares waits.
    hub.dispatch("providerSettings.registrySearch", json!({"query": "x"}));
    assert_eq!(count(&hub, "server.searchAcpRegistry"), 1);
    answer(
        &hub,
        "env-1",
        "server.prepareAcpRegistryAgent",
        Ok(json!({"agentId": "gemini-cli", "version": "1.2.3"})),
    );
    let wizard = &page(&hub)["wizard"];
    assert_eq!(wizard["driver"], "acpRegistry");
    assert_eq!(wizard["step"], 1);
    assert_eq!(wizard["steps"], json!(["Provider", "Identity"]));
    assert_eq!(wizard["instanceId"], "acpRegistry_gemini_cli");
    assert_eq!(
        wizard["registry"]["selected"],
        json!({"id": "gemini-cli", "name": "Gemini CLI", "version": "1.2.3"})
    );
    hub.dispatch("providerSettings.wizardSubmit", json!({}));
    assert_eq!(
        written(&hub)["providerInstances"]["acpRegistry_gemini_cli"],
        json!({"driver": "acpRegistry", "enabled": true, "displayName": "Gemini CLI",
               "config": {"agentId": "gemini-cli", "distribution": "auto",
                          "registryIconUrl": "https://cdn.agentclientprotocol.com/gemini-cli.svg"}})
    );
}

#[test]
fn moving_on_from_the_registry_needs_an_agent() {
    let (hub, _dir) = codex_and_claude();
    hub.dispatch("providerSettings.wizardOpen", json!({}));
    hub.dispatch("providerSettings.registryManual", json!({"manual": true}));
    assert_eq!(page(&hub)["wizard"]["driver"], "acpRegistry");
    assert_eq!(
        page(&hub)["wizard"]["steps"],
        json!(["Provider", "Identity", "Config"])
    );
    hub.dispatch("providerSettings.registryManual", json!({"manual": false}));
    hub.dispatch("providerSettings.wizardStep", json!({"step": 1}));
    let wizard = &page(&hub)["wizard"];
    assert_eq!(wizard["step"], 0);
    assert_eq!(
        wizard["registry"]["selectionError"],
        "Select an ACP or configure one manually."
    );
}

#[test]
fn deleting_a_registry_instance_cleans_up_its_managed_binary() {
    let settings = json!({"providerInstances": {"acpRegistry_goose": {
        "driver": "acpRegistry", "enabled": true, "displayName": "Goose",
        "config": {"agentId": "goose"}}}});
    let (hub, _dir) = opened(
        settings,
        vec![
            provider("codex", "codex"),
            provider("acpRegistry_goose", "acpRegistry"),
        ],
        true,
    );
    assert_eq!(card(&hub, "acpRegistry_goose")["custom"], true);
    // A built-in's own slot cannot be deleted.
    hub.dispatch("providerSettings.delete", json!({"instanceId": "codex"}));
    assert_eq!(writes(&hub), 0);

    hub.dispatch(
        "providerSettings.delete",
        json!({"instanceId": "acpRegistry_goose"}),
    );
    assert_eq!(written(&hub)["providerInstances"], json!({}));
    accept_write(&hub, 2);
    assert_eq!(
        last(&hub, "env-1", "server.uninstallAcpRegistryManagedBinary"),
        json!({"agentId": "goose"})
    );
    answer(
        &hub,
        "env-1",
        "server.uninstallAcpRegistryManagedBinary",
        Err(failure("Busy")),
    );
    assert!(toasts(&hub).contains(&(
        "Provider deleted, but managed files remain".into(),
        "Busy".into()
    )));
}

// ---- Instances -------------------------------------------------------------

#[test]
fn renaming_and_an_accent_edit_the_instance() {
    let (hub, _dir) = codex_and_claude();
    hub.dispatch(
        "providerSettings.rename",
        json!({"instanceId": "codex", "name": " Personal "}),
    );
    assert_eq!(
        written(&hub)["providerInstances"]["codex"],
        json!({"driver": "codex", "displayName": "Personal"})
    );
    accept_write(&hub, 2);
    assert_eq!(card(&hub, "codex")["label"], "Personal");
    assert_eq!(card(&hub, "codex")["resettable"], true);

    hub.dispatch(
        "providerSettings.accent",
        json!({"instanceId": "codex", "color": "#00FF00"}),
    );
    assert_eq!(
        written(&hub)["providerInstances"]["codex"]["accentColor"],
        "#00ff00"
    );
    accept_write(&hub, 3);
    // Clearing the accent drops it.
    hub.dispatch(
        "providerSettings.accent",
        json!({"instanceId": "codex", "color": ""}),
    );
    assert!(
        written(&hub)["providerInstances"]["codex"]
            .get("accentColor")
            .is_none()
    );
    accept_write(&hub, 4);

    hub.dispatch("providerSettings.reset", json!({"instanceId": "codex"}));
    let reset = written(&hub);
    assert_eq!(reset["providerInstances"], json!({}));
    assert_eq!(reset["providers"], json!({}));
}

#[test]
fn a_variable_is_saved_once_complete_and_kept_as_a_secret() {
    let (hub, _dir) = codex_and_claude();
    hub.dispatch(
        "providerSettings.addVariable",
        json!({"instanceId": "codex"}),
    );
    assert_eq!(
        card(&hub, "codex")["variables"].as_array().unwrap().len(),
        1
    );
    // A name the environment cannot use is not saved.
    hub.dispatch(
        "providerSettings.variable",
        json!({"instanceId": "codex", "index": 0, "name": "1BAD"}),
    );
    assert_eq!(card(&hub, "codex")["variables"][0]["invalid"], true);
    assert_eq!(writes(&hub), 0);

    hub.dispatch(
        "providerSettings.variable",
        json!({"instanceId": "codex", "index": 0, "name": "API_TOKEN"}),
    );
    hub.dispatch(
        "providerSettings.variable",
        json!({"instanceId": "codex", "index": 0, "value": "s3cret"}),
    );
    settle(&hub);
    // Each complete edit is saved; the last one carries the value.
    assert_eq!(
        written(&hub)["providerInstances"]["codex"]["environment"],
        json!([{"name": "API_TOKEN", "value": "s3cret", "sensitive": true}])
    );
    // The environment keeps it as a secret.
    let mut settings = written(&hub);
    settings["providerInstances"]["codex"]["environment"] =
        json!([{"name": "API_TOKEN", "value": "", "sensitive": true, "valueRedacted": true}]);
    while hub.mc.pending_on("env-1", WRITE).is_some() {
        answer(&hub, "env-1", WRITE, Ok(json!({"version": 9})));
    }
    send_config(
        &hub,
        json!({"settings": settings, "providers": [provider("codex", "codex"), provider("claudeAgent", "claudeAgent")]}),
        9,
    );
    let row = &card(&hub, "codex")["variables"][0];
    assert_eq!(row["redacted"], true);
    assert_eq!(row["value"], "");
    assert_eq!(
        row["placeholder"],
        "Stored secret, enter a new value to replace"
    );

    // Renamed, it asks for its value again.
    hub.dispatch(
        "providerSettings.variable",
        json!({"instanceId": "codex", "index": 0, "name": "OTHER_TOKEN"}),
    );
    assert_eq!(card(&hub, "codex")["variables"][0]["redacted"], false);

    hub.dispatch(
        "providerSettings.removeVariable",
        json!({"instanceId": "codex", "index": 0}),
    );
    assert!(
        written(&hub)["providerInstances"]["codex"]
            .get("environment")
            .is_none()
    );
}

#[test]
fn cursors_api_key_takes_the_place_of_browser_sign_in() {
    let (hub, _dir) = opened(json!({}), vec![provider("cursor", "cursor")], true);
    auth(&hub, "cursor", signed_out("cursor"));
    assert_eq!(card(&hub, "cursor")["account"]["canSignIn"], true);
    assert_eq!(card(&hub, "cursor")["secrets"][0]["stored"], false);

    hub.dispatch(
        "providerSettings.secret",
        json!({"instanceId": "cursor", "name": "CURSOR_API_KEY", "value": " key-1 "}),
    );
    assert_eq!(
        written(&hub)["providerInstances"]["cursor"]["environment"],
        json!([{"name": "CURSOR_API_KEY", "value": "key-1", "sensitive": true}])
    );
    accept_write(&hub, 2);
    let account = &card(&hub, "cursor")["account"];
    assert_eq!(
        account["description"],
        "Using CURSOR_API_KEY. Remove it from this provider's environment to use browser sign-in."
    );
    assert_eq!(account["canSignIn"], false);

    hub.dispatch(
        "providerSettings.secret",
        json!({"instanceId": "cursor", "name": "CURSOR_API_KEY", "value": ""}),
    );
    accept_write(&hub, 3);
    assert_eq!(card(&hub, "cursor")["account"]["canSignIn"], true);
}

#[test]
fn custom_models_are_added_and_antigravity_takes_none() {
    let (hub, _dir) = opened(
        json!({}),
        vec![
            provider("codex", "codex"),
            provider("antigravity", "antigravity"),
        ],
        true,
    );
    assert_eq!(card(&hub, "antigravity")["takesModels"], false);
    assert_eq!(card(&hub, "codex")["takesModels"], true);
    hub.dispatch(
        "providerSettings.addModel",
        json!({"instanceId": "codex", "slug": "my-model"}),
    );
    let models = &written(&hub)["providerInstances"]["codex"]["config"]["customModels"];
    // A model added by its slug alone is stored as that slug.
    assert_eq!(models, &json!(["my-model"]));
    accept_write(&hub, 2);
    assert_eq!(card(&hub, "codex")["customModels"][0]["slug"], "my-model");
    // One already offered is refused.
    hub.dispatch(
        "providerSettings.addModel",
        json!({"instanceId": "codex", "slug": "fast-one"}),
    );
    assert_ne!(card(&hub, "codex")["modelError"], "");
    assert_eq!(writes(&hub), 1);
}

// ---- This device's models --------------------------------------------------

#[test]
fn hiding_and_moving_models_is_this_devices_own() {
    let (hub, _dir) = codex_and_claude();
    hub.dispatch(
        "providerSettings.modelHidden",
        json!({"instanceId": "codex", "slug": "big-one", "hidden": true}),
    );
    let codex = card(&hub, "codex");
    assert_eq!(codex["modelSummary"], "2 models · 1 hidden");
    assert_eq!(writes(&hub), 0);

    hub.dispatch(
        "providerSettings.modelMove",
        json!({"instanceId": "codex", "slug": "big-one", "by": -1}),
    );
    let slugs: Vec<_> = card(&hub, "codex")["models"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["slug"].clone())
        .collect();
    assert_eq!(slugs, [json!("big-one"), json!("fast-one")]);

    hub.dispatch(
        "providerSettings.filterModels",
        json!({"instanceId": "codex", "query": "fast"}),
    );
    let codex = card(&hub, "codex");
    assert_eq!(codex["modelFilter"], "fast");
}

// ---- Health and hubs -------------------------------------------------------

#[test]
fn the_health_interval_saves_and_resets() {
    let (hub, _dir) = codex_and_claude();
    let health = &page(&hub)["health"];
    assert_eq!(health["step"], 30);
    let preset = health["defaultSeconds"].clone();
    assert_eq!(health["seconds"], preset);
    hub.dispatch("providerSettings.healthInterval", json!({"seconds": 120}));
    let saved = written(&hub);
    accept_write(&hub, 2);
    assert_eq!(page(&hub)["health"]["seconds"], 120, "{saved}");
    hub.dispatch("providerSettings.resetHealthInterval", json!({}));
    accept_write(&hub, 3);
    assert_eq!(page(&hub)["health"]["seconds"], preset);
}

#[test]
fn a_hub_is_named_after_its_host_and_removed_by_its_id() {
    let (hub, _dir) = codex_and_claude();
    hub.dispatch(
        "providerSettings.addHub",
        json!({"url": "https://proxy.example:8317", "key": ""}),
    );
    assert_eq!(writes(&hub), 0);
    hub.dispatch(
        "providerSettings.addHub",
        json!({"url": "https://proxy.example:8317", "key": "k-1"}),
    );
    let sources = written(&hub)["usageLimitSources"].clone();
    let (id, saved) = sources.as_object().unwrap().iter().next().unwrap();
    assert_eq!(
        saved,
        &json!({"kind": "cliproxy", "url": "https://proxy.example:8317",
                "managementKey": "k-1", "enabled": true})
    );
    let id = id.clone();
    accept_write(&hub, 2);
    let hubs = &page(&hub)["hubs"];
    assert_eq!(hubs[0]["label"], "proxy.example:8317");
    assert_eq!(
        hubs[0]["description"],
        "CLI Proxy · https://proxy.example:8317"
    );

    hub.dispatch("providerSettings.removeHub", json!({"id": id}));
    assert_eq!(written(&hub)["usageLimitSources"], json!({}));
}

// ---- Sign-in ---------------------------------------------------------------

#[test]
fn signing_in_from_the_browser_and_cancelling() {
    let (hub, _dir) = codex_and_claude();
    // Unknown until the environment says.
    assert_eq!(card(&hub, "codex")["account"]["canSignIn"], false);
    auth(&hub, "codex", signed_out("codex"));
    let account = &card(&hub, "codex")["account"];
    assert_eq!(account["canSignIn"], true);
    assert_eq!(account["description"], "Sign in on Laptop.");

    hub.dispatch(
        "providerSettings.signIn",
        json!({"instanceId": "codex", "methodId": "nope"}),
    );
    // A method the environment does not offer is the default.
    assert_eq!(
        last(&hub, "env-1", "provider.auth.start"),
        json!({"instanceId": "codex"})
    );
    assert_eq!(card(&hub, "codex")["account"]["canSignIn"], false);
    // One sign-in call at a time.
    hub.dispatch("providerSettings.signIn", json!({"instanceId": "codex"}));
    assert_eq!(count(&hub, "provider.auth.start"), 1);
    answer(&hub, "env-1", "provider.auth.start", Ok(json!({})));
    auth(&hub, "codex", browser_flow("codex"));
    let account = &card(&hub, "codex")["account"];
    assert_eq!(account["description"], "Finish signing in in your browser.");
    assert_eq!(account["url"], "https://auth.example/codex");
    assert_eq!(account["canCancel"], true);
    assert_eq!(account["acceptsCallback"], true);

    hub.dispatch(
        "providerSettings.signInCallback",
        json!({"instanceId": "codex", "url": " http://localhost:1455/cb?code=1 "}),
    );
    assert_eq!(
        last(&hub, "env-1", "provider.auth.complete"),
        json!({"instanceId": "codex", "flowId": "flow-1",
               "callbackUrl": "http://localhost:1455/cb?code=1"})
    );
    answer(
        &hub,
        "env-1",
        "provider.auth.complete",
        Err(failure("Bad code")),
    );
    assert_eq!(card(&hub, "codex")["account"]["error"], "Bad code");

    hub.dispatch(
        "providerSettings.cancelSignIn",
        json!({"instanceId": "codex"}),
    );
    assert_eq!(
        last(&hub, "env-1", "provider.auth.cancel"),
        json!({"instanceId": "codex", "flowId": "flow-1"})
    );
}

#[test]
fn a_sign_in_answered_after_the_user_moved_on_is_ignored() {
    let (hub, _dir) = codex_and_claude();
    auth(&hub, "codex", signed_out("codex"));
    hub.dispatch("providerSettings.signIn", json!({"instanceId": "codex"}));
    hub.dispatch("providerSettings.environment", json!({"id": "env-2"}));
    hub.dispatch("providerSettings.environment", json!({"id": "env-1"}));
    send_config(
        &hub,
        json!({"settings": {}, "providers": [provider("codex", "codex"), provider("claudeAgent", "claudeAgent")]}),
        1,
    );
    auth(&hub, "codex", signed_out("codex"));
    hub.dispatch("providerSettings.signIn", json!({"instanceId": "codex"}));
    assert_eq!(count(&hub, "provider.auth.start"), 2);
    answer(&hub, "env-1", "provider.auth.start", Err(failure("Stale")));
    // The first answer belongs to the earlier visit: the second still waits.
    let account = &card(&hub, "codex")["account"];
    assert_eq!(account["error"], "");
    assert_eq!(account["canSignIn"], false);
}

#[test]
fn terminal_keystrokes_go_one_request_at_a_time_in_order() {
    let (hub, _dir) = codex_and_claude();
    auth(&hub, "codex", terminal_flow("codex"));
    let terminal = &card(&hub, "codex")["account"]["terminal"];
    assert_eq!(terminal["key"], "flow-1:term-1");
    assert_eq!(terminal["output"], "Paste the code: ");
    assert_eq!(terminal["offset"], 16.0);

    let long: String = "x".repeat(5000);
    hub.dispatch(
        "providerSettings.signInTerminal",
        json!({"instanceId": "codex", "data": long, "columns": 80, "rows": 24}),
    );
    hub.dispatch(
        "providerSettings.signInTerminal",
        json!({"instanceId": "codex", "data": "\r"}),
    );
    assert_eq!(pending_respond(&hub), 1);
    let first = last(&hub, "env-1", "provider.auth.respond");
    assert_eq!(first["flowId"], "flow-1");
    assert_eq!(first["interactionId"], "term-1");
    assert_eq!(first["response"]["size"], json!({"cols": 80, "rows": 24}));
    assert_eq!(first["response"]["data"].as_str().unwrap().len(), 4096);
    answer(&hub, "env-1", "provider.auth.respond", Ok(json!({})));
    assert_eq!(
        last(&hub, "env-1", "provider.auth.respond")["response"]["data"]
            .as_str()
            .unwrap()
            .len(),
        904
    );
    answer(&hub, "env-1", "provider.auth.respond", Ok(json!({})));
    assert_eq!(
        last(&hub, "env-1", "provider.auth.respond")["response"],
        json!({"type": "terminal", "data": "\r"})
    );
    // A terminal gone drops what was still queued.
    hub.dispatch(
        "providerSettings.signInTerminal",
        json!({"instanceId": "codex", "data": "a"}),
    );
    answer(&hub, "env-1", "provider.auth.respond", Ok(json!({})));
    answer(&hub, "env-1", "provider.auth.respond", Err(failure("gone")));
    assert_eq!(
        card(&hub, "codex")["account"]["error"],
        "The provider sign-in terminal is no longer available."
    );
    assert_eq!(pending_respond(&hub), 0);
}

#[test]
fn signing_out_asks_first() {
    let mut codex = provider("codex", "codex");
    codex["auth"] =
        json!({"status": "authenticated", "email": "me@example.com", "canLogout": true});
    let (hub, _dir) = opened(json!({}), vec![codex], true);
    auth(&hub, "codex", signed_out("codex"));
    let codex = card(&hub, "codex");
    assert_eq!(codex["headline"], "Authenticated");
    assert_eq!(codex["email"], "me@example.com");
    assert_eq!(codex["account"]["canSignOut"], true);
    assert_eq!(codex["account"]["signInLabel"], "Change account");

    hub.dispatch("providerSettings.signOut", json!({"instanceId": "codex"}));
    confirm(&hub, "Sign out?", false);
    assert_eq!(count(&hub, "provider.auth.logout"), 0);
    hub.dispatch("providerSettings.signOut", json!({"instanceId": "codex"}));
    confirm(&hub, "Sign out?", true);
    assert_eq!(
        last(&hub, "env-1", "provider.auth.logout"),
        json!({"instanceId": "codex"})
    );
}

#[test]
fn credentials_are_sent_for_the_fields_asked() {
    let (hub, _dir) = codex_and_claude();
    auth(
        &hub,
        "claudeAgent",
        json!({"phase": "waiting", "flowId": "flow-2",
               "interaction": {"id": "c-1", "type": "credentials",
                               "fields": [{"name": "token", "label": "Token", "secret": true}]}}),
    );
    let account = &card(&hub, "claudeAgent")["account"];
    assert_eq!(account["description"], "Enter your credentials below.");
    assert_eq!(
        account["credentials"],
        json!([{"name": "token", "label": "Token", "secret": true}])
    );
    hub.dispatch(
        "providerSettings.signInCredentials",
        json!({"instanceId": "claudeAgent", "values": {"token": "t-1", "extra": "no"}}),
    );
    assert_eq!(
        last(&hub, "env-1", "provider.auth.respond"),
        json!({"instanceId": "claudeAgent", "flowId": "flow-2", "interactionId": "c-1",
               "response": {"type": "credentials", "values": {"token": "t-1"}}})
    );
}

// ---- Versions --------------------------------------------------------------

#[test]
fn an_update_runs_on_the_environment() {
    let mut codex = provider("codex", "codex");
    codex["versionAdvisory"] = json!({"status": "behind_latest", "canUpdate": true,
        "latestVersion": "1.3.0", "updateCommand": "npm install -g @openai/codex@latest"});
    let (hub, _dir) = opened(json!({}), vec![codex], true);
    let codex = card(&hub, "codex");
    assert_eq!(
        codex["advisory"],
        json!({"title": "Update available", "detail": "Install v1.3.0.",
               "updateCommand": "npm install -g @openai/codex@latest",
               "targetVersion": null, "strong": false})
    );
    assert_eq!(codex["canUpdate"], true);

    hub.dispatch("providerSettings.update", json!({"instanceId": "codex"}));
    assert_eq!(
        last(&hub, "env-1", "server.updateProvider"),
        json!({"provider": "codex", "instanceId": "codex"})
    );
    assert_eq!(card(&hub, "codex")["updating"], true);
    hub.dispatch("providerSettings.update", json!({"instanceId": "codex"}));
    assert_eq!(count(&hub, "server.updateProvider"), 1);
    answer(
        &hub,
        "env-1",
        "server.updateProvider",
        Err(failure("npm missing")),
    );
    assert_eq!(card(&hub, "codex")["updating"], false);
    assert!(toasts(&hub).contains(&("Could not update codex".into(), "npm missing".into())));
}

#[test]
fn a_recommended_version_is_installed_in_place_of_the_latest() {
    let mut claude = provider("claudeAgent", "claudeAgent");
    claude["compatibilityAdvisory"] = json!({"status": "broken", "recommendedVersion": "2.0.1",
        "message": "This version drops sessions."});
    claude["versionAdvisory"] = json!({"status": "behind_latest", "canInstallVersion": true});
    let (hub, _dir) = opened(json!({}), vec![claude], true);
    let claude = card(&hub, "claudeAgent");
    assert_eq!(claude["advisory"]["title"], "Known broken version");
    assert_eq!(claude["advisory"]["strong"], true);
    assert_eq!(claude["installLabel"], "Install v2.0.1");
    hub.dispatch(
        "providerSettings.install",
        json!({"instanceId": "claudeAgent"}),
    );
    assert_eq!(
        last(&hub, "env-1", "server.updateProvider"),
        json!({"provider": "claudeAgent", "instanceId": "claudeAgent", "targetVersion": "2.0.1"})
    );
}

// ---- The managed runtime ---------------------------------------------------

#[test]
fn the_antigravity_runtime_installs_cancels_and_is_removed() {
    let mut antigravity = provider("antigravity", "antigravity");
    antigravity["installed"] = json!(false);
    antigravity["setup"] = json!({"canAuthenticate": false, "canInstall": true});
    let (hub, _dir) = opened(
        json!({}),
        vec![provider("codex", "codex"), antigravity],
        true,
    );
    // Only the runtime the MC manages is followed.
    assert!(shape(&hub, "providerInstall", "codex").is_none());
    let (_, followed) = shape(&hub, "providerInstall", "antigravity").unwrap();
    assert_eq!(followed["mc"], "mc-1");
    assert_eq!(card(&hub, "antigravity")["runtime"], Json::Null);

    install(
        &hub,
        "antigravity",
        json!({"phase": "idle", "totalBytes": 120_500_000}),
    );
    let runtime = &card(&hub, "antigravity")["runtime"];
    assert_eq!(runtime["status"], "121 MB download.");
    assert_eq!(runtime["installLabel"], "Install Antigravity");
    hub.dispatch(
        "providerSettings.runtimeInstall",
        json!({"instanceId": "antigravity"}),
    );
    assert_eq!(
        last(&hub, "env-1", "provider.install.start"),
        json!({"instanceId": "antigravity"})
    );
    answer(&hub, "env-1", "provider.install.start", Ok(json!({})));
    install(
        &hub,
        "antigravity",
        json!({"phase": "downloading", "operationId": "op-1",
               "downloadedBytes": 30_000_000, "totalBytes": 120_000_000}),
    );
    let runtime = &card(&hub, "antigravity")["runtime"];
    assert_eq!(runtime["status"], "Downloading 30.0 MB of 120.0 MB.");
    assert_eq!(runtime["progress"], 0.25);
    assert_eq!(runtime["canCancel"], true);
    assert_eq!(runtime["installLabel"], "");
    hub.dispatch(
        "providerSettings.runtimeCancel",
        json!({"instanceId": "antigravity"}),
    );
    assert_eq!(
        last(&hub, "env-1", "provider.install.cancel"),
        json!({"instanceId": "antigravity", "operationId": "op-1"})
    );
    answer(&hub, "env-1", "provider.install.cancel", Ok(json!({})));
    install(
        &hub,
        "antigravity",
        json!({"phase": "cancelled", "message": "The previous runtime is unchanged.",
               "installedVersion": "1.0.0", "canRemove": true}),
    );
    let runtime = &card(&hub, "antigravity")["runtime"];
    assert_eq!(runtime["status"], "Installed.");
    assert_eq!(runtime["message"], "The previous runtime is unchanged.");
    assert_eq!(runtime["installLabel"], "Reinstall Antigravity");

    hub.dispatch(
        "providerSettings.runtimeRemove",
        json!({"instanceId": "antigravity"}),
    );
    confirm(&hub, "Remove runtime?", true);
    assert_eq!(
        last(&hub, "env-1", "provider.install.remove"),
        json!({"instanceId": "antigravity"})
    );
    answer(
        &hub,
        "env-1",
        "provider.install.remove",
        Err(failure("In use")),
    );
    assert_eq!(card(&hub, "antigravity")["runtime"]["error"], "In use");
}

// ---- A registry agent's sessions -------------------------------------------

#[test]
fn a_registry_agents_sessions_are_listed_imported_and_deleted() {
    let mut goose = provider("acpRegistry_goose", "acpRegistry");
    goose["setup"] = json!({});
    goose["nativeSessions"] = json!({"canList": true, "canLoad": true, "canDelete": true});
    let (hub, _dir) = opened(
        json!({"providerInstances": {"acpRegistry_goose": {"driver": "acpRegistry", "config": {"agentId": "goose"}}}}),
        vec![goose],
        true,
    );
    let acp = &card(&hub, "acpRegistry_goose")["acp"];
    assert_eq!(acp["projects"], json!([{"id": "p1", "title": "Ljos"}]));
    assert_eq!(acp["projectId"], "p1");
    assert_eq!(acp["sessions"], Json::Null);
    assert_eq!(acp["canImport"], true);

    hub.dispatch(
        "providerSettings.acpSessions",
        json!({"instanceId": "acpRegistry_goose"}),
    );
    assert_eq!(
        last(&hub, "env-1", "server.listAcpRegistrySessions"),
        json!({"instanceId": "acpRegistry_goose", "projectId": "p1"})
    );
    assert_eq!(card(&hub, "acpRegistry_goose")["acp"]["busy"], "sessions");
    // One request at a time.
    hub.dispatch(
        "providerSettings.acpProviders",
        json!({"instanceId": "acpRegistry_goose"}),
    );
    assert_eq!(count(&hub, "server.listAcpRegistryProviders"), 0);
    answer(
        &hub,
        "env-1",
        "server.listAcpRegistrySessions",
        Ok(
            json!({"sessions": [{"sessionId": "s-1", "title": "Fix it", "cwd": "/w/ljos"},
                               {"sessionId": "s-2", "importedThreadId": "t-9"}],
                  "nextCursor": "c-2"}),
        ),
    );
    let acp = &card(&hub, "acpRegistry_goose")["acp"];
    assert_eq!(acp["busy"], "");
    assert_eq!(acp["more"], true);
    assert_eq!(acp["sessions"][1]["title"], "s-2");
    assert_eq!(acp["sessions"][1]["imported"], true);

    hub.dispatch(
        "providerSettings.acpSessions",
        json!({"instanceId": "acpRegistry_goose", "more": true}),
    );
    assert_eq!(
        last(&hub, "env-1", "server.listAcpRegistrySessions")["cursor"],
        "c-2"
    );
    answer(
        &hub,
        "env-1",
        "server.listAcpRegistrySessions",
        Ok(json!({"sessions": [{"sessionId": "s-3"}]})),
    );
    let acp = &card(&hub, "acpRegistry_goose")["acp"];
    assert_eq!(acp["sessions"].as_array().unwrap().len(), 3);
    assert_eq!(acp["more"], false);

    hub.dispatch(
        "providerSettings.acpDelete",
        json!({"instanceId": "acpRegistry_goose", "sessionId": "s-1"}),
    );
    let question = hub.published("confirmation");
    hub.dispatch(
        "confirmation.answer",
        json!({"requestId": question["requestId"], "accepted": true}),
    );
    assert_eq!(
        last(&hub, "env-1", "server.deleteAcpRegistrySession")["sessionId"],
        "s-1"
    );
}

// ---- The wizard and instance edits, interleaved ----------------------------

#[derive(Clone, Debug)]
enum Step {
    Open,
    Close,
    Driver(usize),
    Label(usize),
    InstanceId(usize),
    Move(i64),
    Submit,
    Rename(usize),
    AddVariable,
    VariableName(usize, usize),
    VariableValue(usize),
    RemoveVariable(usize),
    Enable(bool),
    /// The settings reads in flight are answered with the document the MC
    /// holds.
    Read,
    /// The oldest settings write is accepted (true) or refused.
    Write(bool),
}

const DRIVERS: [&str; 5] = ["codex", "claudeAgent", "cursor", "opencode", "acpRegistry"];
const LABELS: [&str; 4] = ["", "Work", "Claude", "Two words"];
const IDS: [&str; 5] = ["codex", "codex_work", "1bad", "fresh", ""];
const NAMES: [&str; 4] = ["API_TOKEN", "1BAD", "", "OTHER"];

fn step() -> impl Strategy<Value = Step> {
    prop_oneof![
        2 => Just(Step::Open),
        1 => Just(Step::Close),
        2 => (0..DRIVERS.len()).prop_map(Step::Driver),
        2 => (0..LABELS.len()).prop_map(Step::Label),
        2 => (0..IDS.len()).prop_map(Step::InstanceId),
        3 => (-1..4i64).prop_map(Step::Move),
        3 => Just(Step::Submit),
        1 => (0..LABELS.len()).prop_map(Step::Rename),
        2 => Just(Step::AddVariable),
        2 => (0..3usize, 0..NAMES.len()).prop_map(|(i, n)| Step::VariableName(i, n)),
        2 => (0..3usize).prop_map(Step::VariableValue),
        1 => (0..3usize).prop_map(Step::RemoveVariable),
        1 => any::<bool>().prop_map(Step::Enable),
        3 => Just(Step::Read),
        4 => any::<bool>().prop_map(Step::Write),
    ]
}

/// Whether every variable a document sets has a name the environment can
/// use.
fn variables_valid(document: &Json) -> bool {
    document["providerInstances"]
        .as_object()
        .into_iter()
        .flat_map(|i| i.values())
        .flat_map(|i| i["environment"].as_array().cloned().unwrap_or_default())
        .all(|v| instances::valid_variable_name(v["name"].as_str().unwrap_or_default()))
}

fn listed() -> Json {
    json!([
        provider("codex", "codex"),
        provider("claudeAgent", "claudeAgent")
    ])
}

/// Answers the oldest write as the MC would: an accepted one becomes the
/// document everyone hears.
fn answer_write(hub: &Hub, accepted: bool, version: &mut i64, held: &mut Json) {
    let Some(index) = hub.mc.pending_on("env-1", WRITE) else {
        return;
    };
    if accepted {
        let document = hub.mc.calls.borrow()[index].2["settings"].clone();
        *held = document.clone();
        *version += 1;
        hub.mc
            .reply(&hub.engine, index, Ok(json!({"version": *version})));
        send_config(
            hub,
            json!({"settings": document, "providers": listed()}),
            *version,
        );
    } else {
        hub.mc.reply(&hub.engine, index, Err(failure("Refused")));
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(64))]

    /// The add-provider wizard and an instance's edits, interleaved with the
    /// environment's settings reads and writes answered in any order: the
    /// wizard saves only a valid instance, closes only when the user closes it
    /// or its save went through, changes nothing while it saves, and every
    /// write keeps the variables valid.
    #[test]
    fn the_wizard_and_instance_edits_keep_their_promises(
        steps in proptest::collection::vec(step(), 1..32)
    ) {
        let (hub, _dir) = codex_and_claude();
        let mut version = 1;
        let mut document = json!({});
        for step in &steps {
            let before = page(&hub)["wizard"].clone();
            let reads = count(&hub, READ);
            let saving = before["saving"] == true;
            match step {
                Step::Open => hub.dispatch("providerSettings.wizardOpen", json!({})),
                Step::Close => hub.dispatch("providerSettings.wizardClose", json!({})),
                Step::Driver(i) => hub.dispatch("providerSettings.wizardDriver", json!({"driver": DRIVERS[*i]})),
                Step::Label(i) => hub.dispatch("providerSettings.wizardLabel", json!({"label": LABELS[*i]})),
                Step::InstanceId(i) => hub.dispatch("providerSettings.wizardInstanceId", json!({"instanceId": IDS[*i]})),
                Step::Move(to) => hub.dispatch("providerSettings.wizardStep", json!({"step": to})),
                Step::Submit => hub.dispatch("providerSettings.wizardSubmit", json!({})),
                Step::Rename(i) => hub.dispatch("providerSettings.rename", json!({"instanceId": "codex", "name": LABELS[*i]})),
                Step::AddVariable => hub.dispatch("providerSettings.addVariable", json!({"instanceId": "codex"})),
                Step::VariableName(i, n) => hub.dispatch("providerSettings.variable", json!({"instanceId": "codex", "index": i, "name": NAMES[*n]})),
                Step::VariableValue(i) => hub.dispatch("providerSettings.variable", json!({"instanceId": "codex", "index": i, "value": "v"})),
                Step::RemoveVariable(i) => hub.dispatch("providerSettings.removeVariable", json!({"instanceId": "codex", "index": i})),
                Step::Enable(on) => hub.dispatch("providerSettings.enable", json!({"instanceId": "claudeAgent", "enabled": on})),
                Step::Read => settle(&hub),
                Step::Write(accepted) => answer_write(&hub, *accepted, &mut version, &mut document),
            }
            let after = page(&hub)["wizard"].clone();

            // Every write sent keeps the variables valid.
            for (_, method, payload) in hub.mc.calls.borrow().iter() {
                if method == WRITE {
                    prop_assert!(variables_valid(&payload["settings"]), "{}", payload);
                }
            }
            match (&before, &after) {
                (Json::Null, Json::Null) => {}
                (Json::Null, _) => prop_assert!(matches!(step, Step::Open), "{:?}", step),
                (_, Json::Null) => prop_assert!(
                    (matches!(step, Step::Close) && !saving)
                        || (matches!(step, Step::Write(true)) && saving),
                    "{:?} closed {}", step, before
                ),
                (_, _) => {
                    // A wizard that saves changes nothing until its write is answered.
                    if saving && !matches!(step, Step::Open | Step::Write(_)) {
                        prop_assert_eq!(&before, &after, "{:?}", step);
                    }
                    let steps = after["steps"].as_array().unwrap().len() as i64;
                    let at = after["step"].as_i64().unwrap();
                    prop_assert!((0..steps).contains(&at), "{}", after);
                    // Moving on past Identity needs a valid id.
                    if matches!(step, Step::Move(_)) && before["step"].as_i64() <= Some(1) && at > 1 {
                        let taken = instances::taken(&document, listed().as_array().unwrap());
                        let id = after["instanceId"].as_str().unwrap_or_default();
                        prop_assert_eq!(drivers::validate_id(id, &taken), "", "{}", after);
                    }
                    // A submit that starts saving reads the document to write.
                    if matches!(step, Step::Submit) && !saving && after["saving"] == true {
                        prop_assert_eq!(count(&hub, READ), reads + 1);
                        prop_assert_eq!(&after["instanceIdError"], &json!(""));
                    }
                    if matches!(step, Step::Submit) && !saving && after["saving"] != true {
                        prop_assert!(
                            after["instanceIdError"] != "" || after["registry"]["selectionError"] != "",
                            "{}", after
                        );
                    }
                }
            }
        }
        // Once every read and write is answered, nothing is left saving.
        for _ in 0..64 {
            settle(&hub);
            if hub.mc.pending_on("env-1", WRITE).is_none() {
                break;
            }
            answer_write(&hub, true, &mut version, &mut document);
        }
        prop_assert!(page(&hub)["wizard"]["saving"] != true);
    }
}
