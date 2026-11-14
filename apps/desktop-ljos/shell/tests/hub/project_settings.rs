//! `projectSettings`: Settings → Project, the picked project's name, icon,
//! checkouts and the defaults new threads start with
//! (ProjectSettingsController.cpp, features/projects/settings.feature).

use hal_c2_shell::controllers::sidebar;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::McError;
use serde_json::json;

use crate::Hub;

const AT: &str = "2026-03-01T00:00:00Z";
const MUTATE: &str = "projects.mutate";
const READ: &str = "hal-c2.readSettings";
const WRITE: &str = "hal-c2.writeSettings";

/// One logical project, "shop", with a checkout on the laptop (`env-1`) and
/// one on the build box (`env-2`, online unless `build_box_online` is off),
/// and the laptop offering one model.
fn hub(build_box_online: bool) -> Hub {
    let hub = Hub::clustered();
    hub.mc.set_ready(&hub.engine, true);
    shell(&hub, build_box_online, true, true);
    hub.dispatch("settings.navigate", json!({"to": "/settings/projects"}));
    for (environment, models) in [
        ("env-1", json!([{"slug": "sonnet", "name": "Sonnet"}])),
        ("env-2", json!([])),
    ] {
        config(&hub, environment, json!({}), models);
    }
    hub
}

/// The cluster as the shell frame says it, with shop's checkout on each
/// machine that `laptop` and `build_box` name.
fn shell(hub: &Hub, build_box_online: bool, laptop: bool, build_box: bool) {
    let row = |mc: &str, id: &str, root: &str| {
        json!([mc, id, "project", {"id": id, "title": "Shop", "workspaceRoot": root,
            "repositoryIdentity": {"canonicalKey": "github.com/o/shop", "rootPath": root,
                "displayName": "o/shop", "name": "shop"},
            "createdAt": AT, "updatedAt": AT}])
    };
    let rows: Vec<Json> = [
        laptop.then(|| row("a", "p1", "/w/shop")),
        build_box.then(|| row("b", "p9", "/b/shop")),
    ]
    .into_iter()
    .flatten()
    .collect();
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell", "mcs": [
            {"mc": "a", "online": true, "epoch": "e", "rev": 1,
                "environment": {"environmentId": "env-1", "label": "Laptop",
                    "capabilities": {"projectSettingsOverrides": true}}},
            {"mc": "b", "online": build_box_online, "epoch": "e", "rev": 1,
                "environment": {"environmentId": "env-2", "label": "Build box",
                    "capabilities": {"projectSettingsOverrides": true}}}],
            "rows": rows}),
    );
}

/// An environment's config frame, offering `models`, and the reads it sets
/// off answered with the same `settings`.
fn config(hub: &Hub, environment: &str, settings: Json, models: Json) {
    hub.mc.frame(
        &hub.engine,
        "config",
        environment,
        json!({"t": "config", "config": {"settings": settings,
            "providers": [{"instanceId": "claude", "displayName": "Claude", "enabled": true,
                "installed": true, "models": models}],
            "environment": {"capabilities": {"projectSettingsOverrides": true}}}}),
    );
    while let Some(index) = hub.mc.pending_on(environment, READ) {
        hub.mc.reply(
            &hub.engine,
            index,
            Ok(json!({"settings": settings, "version": 1})),
        );
    }
}

fn state(hub: &Hub) -> Json {
    hub.published("projectSettings")
}

fn pick(hub: &Hub) {
    let key = sidebar::groups(&hub.engine)
        .into_iter()
        .find(|g| g.members.iter().any(|m| m.id == "p1"))
        .expect("shop's group")
        .key;
    hub.dispatch("settingsScope.project", json!({"key": key}));
}

fn calls(hub: &Hub, method: &str) -> Vec<(String, Json)> {
    hub.mc
        .calls
        .borrow()
        .iter()
        .filter(|(_, m, _)| m == method)
        .map(|(e, _, p)| (e.clone(), p.clone()))
        .collect()
}

fn toast_titles(hub: &Hub) -> Vec<String> {
    hub.published("toasts")["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["title"].as_str().unwrap().to_owned())
        .collect()
}

/// Answers the read the write starts with, with `settings`, and returns
/// what is then written.
fn written(hub: &Hub, settings: Json) -> Json {
    hub.mc.answer_on(
        &hub.engine,
        "env-1",
        READ,
        Ok(json!({"settings": settings, "version": 1})),
    );
    let index = hub.mc.pending(WRITE).expect("the settings are written");
    hub.mc.calls.borrow()[index].2["settings"].clone()
}

#[test]
fn without_a_project_the_page_asks_for_one_and_holds_the_environments_defaults() {
    let hub = hub(true);
    let shown = state(&hub);
    assert_eq!(shown["open"], true);
    assert_eq!(shown["status"], "pick");
    assert_eq!(shown["available"], true);
    assert_eq!(shown["permissions"]["value"], "full-access");
    assert_eq!(shown["permissions"]["label"], "Full access");
    assert_eq!(shown["permissions"]["resettable"], false);
    assert_eq!(shown["workspace"]["label"], "Current checkout");
    assert_eq!(shown["model"]["automatic"], true);

    hub.dispatch(
        "projectSettings.permissions",
        json!({"value": "approval-required"}),
    );
    // Nothing outside the choices is written.
    hub.dispatch("projectSettings.permissions", json!({"value": "root"}));
    let settings = written(&hub, json!({}));
    assert_eq!(settings["defaultRuntimeMode"], "approval-required");
    assert!(hub.mc.pending(WRITE).is_some());
}

#[test]
fn off_the_page_nothing_is_open_and_actions_do_nothing() {
    let hub = hub(true);
    hub.dispatch("settings.navigate", json!({"to": "/settings/general"}));
    assert_eq!(state(&hub), json!({"open": false}));
    hub.dispatch("projectSettings.permissions", json!({"value": "auto"}));
    assert!(hub.mc.pending(READ).is_none());
    assert!(calls(&hub, WRITE).is_empty());
}

#[test]
fn a_picked_project_shows_its_name_icon_and_every_checkout() {
    let hub = hub(true);
    pick(&hub);
    let shown = state(&hub);
    assert_eq!(shown["status"], "ready");
    assert_eq!(shown["name"], "Shop");
    assert_eq!(shown["icon"]["label"], "Automatic");
    assert_eq!(shown["icon"]["custom"], false);
    let checkouts: Vec<_> = shown["checkouts"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| {
            (
                c["environment"].as_str().unwrap(),
                c["path"].as_str().unwrap(),
            )
        })
        .collect();
    assert_eq!(checkouts, [("Laptop", "/w/shop"), ("Build box", "/b/shop")]);
    assert_eq!(shown["removal"]["button"], "Remove all entries");

    // One environment's checkout alone leaves the other's out.
    hub.dispatch("settingsScope.environment", json!({"id": "env-1"}));
    let shown = state(&hub);
    assert_eq!(shown["checkouts"].as_array().unwrap().len(), 1);
    assert_eq!(shown["removal"]["button"], "Remove checkout");
}

#[test]
fn a_project_that_went_away_says_so() {
    let hub = hub(true);
    hub.dispatch("settingsScope.project", json!({"key": "github.com/o/gone"}));
    assert_eq!(state(&hub)["status"], "missing");
}

#[test]
fn renaming_goes_to_every_checkout_in_turn_and_a_failure_names_where_it_stopped() {
    let hub = hub(true);
    pick(&hub);
    hub.dispatch("projectSettings.rename", json!({"title": "  "}));
    assert_eq!(toast_titles(&hub), ["Project title cannot be empty"]);
    assert!(calls(&hub, MUTATE).is_empty());

    hub.dispatch("projectSettings.rename", json!({"title": " Store "}));
    // The second waits for the first.
    let sent = calls(&hub, MUTATE);
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].1["type"], "project.update");
    assert_eq!(sent[0].1["title"], "Store");
    let first = hub.mc.pending(MUTATE).unwrap();
    hub.mc.reply(&hub.engine, first, Ok(json!({})));
    let sent = calls(&hub, MUTATE);
    assert_eq!(sent.len(), 2);
    assert_ne!(sent[0].0, sent[1].0);
    let second = hub.mc.pending(MUTATE).unwrap();
    hub.mc
        .reply(&hub.engine, second, Err(McError::new("read-only")));
    let titles = toast_titles(&hub);
    assert!(
        titles
            .iter()
            .any(|t| t.starts_with("Failed to rename project on ")),
        "{titles:?}"
    );
}

#[test]
fn a_checkout_on_a_machine_that_is_not_connected_stops_the_update_before_it_starts() {
    let hub = hub(false);
    pick(&hub);
    hub.dispatch("projectSettings.rename", json!({"title": "Store"}));
    assert!(calls(&hub, MUTATE).is_empty());
    assert_eq!(toast_titles(&hub), ["Failed to rename project"]);
}

#[test]
fn the_icon_is_an_emoji_a_picked_icon_a_file_or_automatic() {
    let hub = hub(true);
    pick(&hub);
    hub.dispatch("settingsScope.environment", json!({"id": "env-1"}));
    let send = |payload: Json| -> Json {
        hub.dispatch("projectSettings.icon", payload);
        let index = hub.mc.pending(MUTATE).expect("an update");
        let sent = hub.mc.calls.borrow()[index].2.clone();
        hub.mc.reply(&hub.engine, index, Ok(json!({})));
        sent
    };
    let sent = send(json!({"emoji": " 🛒 "}));
    assert_eq!(sent["projectIcon"], json!({"kind": "emoji", "emoji": "🛒"}));
    assert_eq!(sent["faviconPath"], Json::Null);
    let sent = send(json!({"icon": {"kind": "lucide", "name": "rocket", "color": "blue"}}));
    assert_eq!(sent["projectIcon"]["name"], "rocket");
    let sent = send(json!({"faviconPath": "/w/shop/icon.png"}));
    assert_eq!(sent["projectIcon"], Json::Null);
    assert_eq!(sent["faviconPath"], "/w/shop/icon.png");
    let sent = send(json!({}));
    assert_eq!(sent["projectIcon"], Json::Null);
    assert_eq!(sent["faviconPath"], Json::Null);
}

#[test]
fn removing_asks_first_for_one_checkout_or_all() {
    let hub = hub(true);
    pick(&hub);
    hub.dispatch("projectSettings.remove", json!({"key": "env-2:p9"}));
    let asked = hub.published("projectRemoval");
    assert_eq!(asked["projectKey"], "env-2:p9");
    assert_eq!(asked["kind"], "checkout");
    assert_eq!(asked["count"], 1);
    hub.dispatch("project.remove.cancel", json!({}));
    assert_eq!(hub.published("projectRemoval"), Json::Null);

    hub.dispatch("projectSettings.remove", json!({}));
    let asked = hub.published("projectRemoval");
    assert_eq!(asked["count"], 2);
    assert_eq!(asked["kind"], "project");
    assert!(calls(&hub, MUTATE).is_empty());
    hub.dispatch("project.remove.confirm", json!({}));
    let sent = calls(&hub, MUTATE);
    assert_eq!(sent[0].1["type"], "project.delete");
    assert_eq!(sent[0].1["force"], true);
}

#[test]
fn a_project_picked_keeps_its_choices_as_overrides_and_reset_drops_them() {
    let hub = hub(true);
    pick(&hub);
    hub.dispatch("settingsScope.environment", json!({"id": "env-1"}));
    hub.dispatch("projectSettings.workspace", json!({"value": "worktree"}));
    let settings = written(&hub, json!({}));
    assert_eq!(
        settings["projectSettingsOverrides"]["p1"]["defaultThreadEnvMode"],
        "worktree"
    );
    hub.mc.reply(
        &hub.engine,
        hub.mc.pending(WRITE).unwrap(),
        Ok(json!({"version": 2})),
    );
    config(
        &hub,
        "env-1",
        json!({"projectSettingsOverrides": {"p1": {"defaultThreadEnvMode": "worktree"}}}),
        json!([{"slug": "sonnet", "name": "Sonnet"}]),
    );
    let shown = state(&hub);
    assert_eq!(shown["workspace"]["value"], "worktree");
    assert_eq!(shown["workspace"]["resettable"], true);
    assert_eq!(shown["permissions"]["resettable"], false);

    hub.dispatch("projectSettings.reset", json!({"key": "workspace"}));
    hub.dispatch("projectSettings.reset", json!({"key": "nonsense"}));
    let calls_before = calls(&hub, READ).len();
    let settings = written(
        &hub,
        json!({"projectSettingsOverrides": {"p1": {"defaultThreadEnvMode": "worktree"}}}),
    );
    assert_eq!(settings, json!({"projectSettingsOverrides": {}}));
    assert!(calls_before >= 1);
}

#[test]
fn a_model_must_be_offered_by_every_environment_in_the_scope() {
    let hub = hub(true);
    // The build box offers no model: the laptop's alone is not shared.
    hub.dispatch("projectSettings.model", json!({"key": "claude:sonnet"}));
    assert_eq!(toast_titles(&hub), ["Default model not saved"]);
    assert!(hub.mc.pending(WRITE).is_none());

    hub.dispatch("settingsScope.environment", json!({"id": "env-1"}));
    hub.dispatch("projectSettings.model", json!({"key": "claude:sonnet"}));
    let settings = written(&hub, json!({}));
    assert_eq!(
        settings["defaultModelSelection"],
        json!({"instanceId": "claude", "model": "sonnet"})
    );
    let shown = state(&hub);
    assert_eq!(
        shown["model"]["models"],
        json!([{"key": "claude:sonnet", "label": "Claude · Sonnet"}])
    );
}

#[test]
fn inspecting_the_model_shows_the_layers_it_resolves_through_and_the_projects_overriding_it() {
    let hub = hub(true);
    hub.dispatch("settingsScope.environment", json!({"id": "env-1"}));
    config(
        &hub,
        "env-1",
        json!({
            "defaultModelSelection": {"instanceId": "claude", "model": "sonnet"},
            "projectSettingsOverrides": {"p1": {"defaultModelSelection":
                {"instanceId": "claude", "model": "opus"}}}}),
        json!([{"slug": "sonnet", "name": "Sonnet"}]),
    );
    assert!(state(&hub)["model"].get("inheritance").is_none());
    hub.dispatch("projectSettings.inspect", json!({"key": "model"}));
    let inheritance = state(&hub)["model"]["inheritance"].clone();
    let layers: Vec<_> = inheritance["layers"]
        .as_array()
        .unwrap()
        .iter()
        .map(|l| {
            (
                l["key"].as_str().unwrap(),
                l["effective"].as_bool().unwrap(),
            )
        })
        .collect();
    assert_eq!(layers, [("environment", true), ("built-in", false)]);
    assert_eq!(inheritance["layers"][0]["value"], "Claude · Sonnet");
    let overriding = inheritance["overridingProjects"].as_array().unwrap();
    assert_eq!(overriding.len(), 1);
    assert_eq!(overriding[0]["projectId"], "p1");
    assert_eq!(overriding[0]["title"], "Shop");
    assert_eq!(overriding[0]["value"], "claude:opus");

    hub.dispatch("projectSettings.inspect", json!({"key": "other"}));
    assert!(state(&hub)["model"].get("inheritance").is_none());
}

#[test]
fn clearing_a_projects_override_leaves_the_others_and_the_environments_value() {
    let hub = hub(true);
    hub.dispatch("settingsScope.environment", json!({"id": "env-1"}));
    let held = json!({"defaultModelSelection": {"instanceId": "claude", "model": "sonnet"},
        "projectSettingsOverrides": {"p1": {"defaultModelSelection":
            {"instanceId": "claude", "model": "opus"}, "defaultRuntimeMode": "auto"}}});
    config(&hub, "env-1", held.clone(), json!([]));
    hub.dispatch(
        "projectSettings.clearOverride",
        json!({"environmentId": "env-1", "projectId": "p1"}),
    );
    let settings = written(&hub, held.clone());
    assert_eq!(
        settings["projectSettingsOverrides"]["p1"],
        json!({"defaultRuntimeMode": "auto"})
    );
    assert_eq!(
        settings["defaultModelSelection"],
        held["defaultModelSelection"]
    );
}

#[test]
fn environments_that_disagree_show_a_default_as_mixed_until_one_value_is_set_on_all() {
    let hub = hub(true);
    config(
        &hub,
        "env-1",
        json!({"defaultRuntimeMode": "auto"}),
        json!([]),
    );
    config(
        &hub,
        "env-2",
        json!({"defaultRuntimeMode": "approval-required"}),
        json!([]),
    );
    let shown = state(&hub);
    assert_eq!(shown["permissions"]["mixed"], true);
    assert_eq!(shown["permissions"]["value"], "");
    assert_eq!(shown["permissions"]["label"], "Mixed");
    assert_eq!(shown["permissions"]["resettable"], true);

    hub.dispatch(
        "projectSettings.permissions",
        json!({"value": "full-access"}),
    );
    for environment in ["env-1", "env-2"] {
        let index = hub.mc.pending_on(environment, READ).expect("each is read");
        hub.mc.reply(
            &hub.engine,
            index,
            Ok(json!({"settings": {"defaultRuntimeMode": "auto"}, "version": 1})),
        );
        let write = hub
            .mc
            .pending_on(environment, WRITE)
            .expect("each is written");
        assert_eq!(
            hub.mc.calls.borrow()[write].2["settings"]["defaultRuntimeMode"],
            "full-access"
        );
    }
}

#[test]
fn a_project_or_checkout_that_goes_away_is_reported_and_no_projects_asks_to_add_one() {
    let hub = hub(true);
    pick(&hub);
    // The build box's checkout goes; looking at that machine finds none.
    shell(&hub, true, true, false);
    hub.dispatch("settingsScope.environment", json!({"id": "env-2"}));
    let shown = state(&hub);
    assert_eq!(shown["status"], "checkout-missing");
    assert_eq!(
        shown["message"],
        "This checkout is no longer available in the selected project and environment."
    );
    // Every checkout goes.
    shell(&hub, true, false, false);
    assert_eq!(state(&hub)["status"], "missing");
    hub.dispatch("settingsScope.project", json!({"key": ""}));
    hub.dispatch("settingsScope.environment", json!({"id": ""}));
    assert_eq!(state(&hub)["status"], "empty");
}
