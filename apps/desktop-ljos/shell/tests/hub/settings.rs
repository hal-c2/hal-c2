//! `Settings` and `settingsScope`: the MC's document read and saved at its
//! version, this device's preferences, and where a change applies
//! (features/settings/scopes-and-inheritance.feature,
//! features/settings/saving-settings.feature).

use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::rc::Rc;

use hal_c2_shell::Launch;
use hal_c2_shell::controllers::settings::{
    ENVIRONMENT_WIDE, KEPT_CHANGING, Map, NOT_LOADED, NOWHERE, Settings, SettingsObject,
};
use hal_c2_shell::controllers::settings_scope::{
    Environment, ProjectGroup, RECONNECT, SettingsScope,
};
use hal_c2_shell::json::{self, Json};
use hal_c2_shell::mc::McError;
use proptest::prelude::*;
use serde_json::json;

use crate::Hub;
use crate::common::{call, js_value};

const READ: &str = "hal-c2.readSettings";
const WRITE: &str = "hal-c2.writeSettings";

fn map(json: Json) -> Map {
    match json {
        Json::Object(map) => map,
        other => panic!("not an object: {other}"),
    }
}

fn stale() -> McError {
    McError {
        message: "stale".into(),
        detail: json!({"_tag": "StaleSettings"}),
    }
}

/// Answers the oldest unanswered call to `method` on `environment`.
fn answer_on(hub: &Hub, environment: &str, method: &str, result: Result<Json, McError>) {
    let index = hub
        .mc
        .pending_on(environment, method)
        .unwrap_or_else(|| panic!("no unanswered {method} on {environment}"));
    hub.mc.reply(&hub.engine, index, result);
}

/// The payload of the last call to `method` on `environment`.
fn last(hub: &Hub, environment: &str, method: &str) -> Json {
    hub.mc
        .calls
        .borrow()
        .iter()
        .rev()
        .find(|(e, m, _)| e == environment && m == method)
        .map(|(_, _, p)| p.clone())
        .unwrap_or_else(|| panic!("no {method} on {environment}"))
}

fn count(hub: &Hub, method: &str) -> usize {
    hub.mc.methods().iter().filter(|m| *m == method).count()
}

/// The MC's config snapshot and the read it sets off.
fn load(hub: &Hub, settings: Json, version: i64) {
    hub.mc.frame(
        &hub.engine,
        "config",
        "env-1",
        json!({"t": "config", "config": {"settings": settings, "keybindingRules": []}}),
    );
    answer_on(
        hub,
        "env-1",
        READ,
        Ok(json!({"settings": settings, "version": version})),
    );
}

fn toasts(hub: &Hub) -> Vec<(String, String)> {
    hub.published("toasts")["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| {
            (
                i["title"].as_str().unwrap_or_default().to_owned(),
                i["description"].as_str().unwrap_or_default().to_owned(),
            )
        })
        .collect()
}

fn object(hub: &Hub, name: &str) -> Json {
    let obj = hub.engine.singleton::<SettingsObject>().expect("Settings");
    json::from_value(&hub.engine, &hub.engine.read_by_name(obj, name))
}

/// A fresh config dir for the test, under the target's scratch space.
fn config_dir(test: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join("hub-settings")
        .join(test);
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

fn with_config(dir: &Path) -> Hub {
    Hub::with(Launch {
        config_dir: Some(dir.to_path_buf()),
        ..Launch::default()
    })
}

#[test]
fn the_document_arrives_with_the_config_snapshot() {
    let hub = Hub::new();
    let settings = Settings::of(&hub.engine);
    assert!(!settings.ready());
    let shape = json!({"type": "config", "environment": "env-1", "usageLimitsCommand": true});
    assert!(hub.mc.subscriptions().iter().any(|(_, s)| *s == shape));
    load(
        &hub,
        json!({"autoResumeLimitedThreads": true, "a": {"b": 2}}),
        4,
    );
    assert!(settings.ready());
    assert_eq!(settings.version(), 4);
    assert_eq!(settings.value("a.b"), Some(json!(2)));
    assert_eq!(
        settings.setting(&hub.engine, "autoResumeLimitedThreads"),
        Some(json!(true))
    );
    // Unset: its default; unknown: nothing.
    assert_eq!(
        settings.setting(&hub.engine, "diffLayout"),
        Some(json!("stacked"))
    );
    assert_eq!(settings.setting(&hub.engine, "nope"), None);
    assert_eq!(object(&hub, "ready"), json!(true));
    assert_eq!(object(&hub, "version"), json!(4));
    assert_eq!(object(&hub, "document")["a"], json!({"b": 2}));
    assert_eq!(object(&hub, "config")["keybindingRules"], json!([]));
}

#[test]
fn qml_reads_and_sets_rows_through_the_singleton() {
    let hub = Hub::new();
    load(&hub, json!({}), 1);
    let obj = hub.engine.singleton::<SettingsObject>().expect("Settings");
    let key = js_value(&hub.engine, "'sidebarAutoSettleAfterDays'");
    assert_eq!(
        call(&hub.engine, obj, "setting", std::slice::from_ref(&key)).to_number(),
        3.0
    );
    // QML's 5.0 goes out as the MC's 5.
    call(
        &hub.engine,
        obj,
        "set",
        &[key, js_value(&hub.engine, "5.0")],
    );
    assert_eq!(
        last(&hub, "env-1", WRITE),
        json!({"settings": {"sidebarAutoSettleAfterDays": 5}, "version": 1})
    );
}

#[test]
fn a_change_is_saved_at_the_version_read_and_a_default_is_stored_as_absence() {
    let hub = Hub::new();
    let settings = Settings::of(&hub.engine);
    load(&hub, json!({"autoResumeLimitedThreads": true}), 7);
    settings.set(&hub.engine, "autoResumeLimitedThreads", json!(false));
    assert_eq!(
        last(&hub, "env-1", WRITE),
        json!({"settings": {}, "version": 7})
    );
    answer_on(&hub, "env-1", WRITE, Ok(json!({"version": 8})));
    assert_eq!(settings.version(), 8);
    assert!(settings.is_default(&hub.engine, "autoResumeLimitedThreads"));
    // Nothing to change: nothing written.
    settings.set(&hub.engine, "autoResumeLimitedThreads", json!(false));
    assert_eq!(count(&hub, WRITE), 1);
}

#[test]
fn a_stale_save_is_edited_again_over_what_the_other_editor_saved() {
    let hub = Hub::new();
    let settings = Settings::of(&hub.engine);
    load(&hub, json!({}), 1);
    settings.write(&hub.engine, "providers.codex.enabled", json!(false));
    answer_on(&hub, "env-1", WRITE, Err(stale()));
    answer_on(
        &hub,
        "env-1",
        READ,
        Ok(json!({"settings": {"wordWrap": false}, "version": 2})),
    );
    assert_eq!(
        last(&hub, "env-1", WRITE),
        json!({"settings": {"wordWrap": false, "providers": {"codex": {"enabled": false}}}, "version": 2})
    );
    answer_on(&hub, "env-1", WRITE, Ok(json!({"version": 3})));
    assert_eq!(
        settings.value("providers.codex.enabled"),
        Some(json!(false))
    );
    assert_eq!(settings.value("wordWrap"), Some(json!(false)));
    assert!(toasts(&hub).is_empty());
}

#[test]
fn a_save_that_stays_stale_gives_up_and_says_so() {
    let hub = Hub::new();
    let settings = Settings::of(&hub.engine);
    load(&hub, json!({}), 1);
    let outcome = Rc::new(RefCell::new(None));
    let seen = outcome.clone();
    settings.change(
        &hub.engine,
        |s| {
            let mut s = s.clone();
            s.insert("k".into(), json!(1));
            s
        },
        move |_, error| *seen.borrow_mut() = Some(error),
    );
    for version in 2..=4 {
        answer_on(&hub, "env-1", WRITE, Err(stale()));
        answer_on(
            &hub,
            "env-1",
            READ,
            Ok(json!({"settings": {}, "version": version})),
        );
    }
    answer_on(&hub, "env-1", WRITE, Err(stale()));
    assert_eq!(*outcome.borrow(), Some(Some(KEPT_CHANGING.to_owned())));
    assert_eq!(settings.error(), KEPT_CHANGING);
    assert_eq!(count(&hub, WRITE), 4);
}

#[test]
fn a_read_overtaken_by_a_save_is_dropped() {
    let hub = Hub::new();
    let settings = Settings::of(&hub.engine);
    load(&hub, json!({}), 1);
    // Another client saved: the push sets off a read.
    hub.mc.frame(
        &hub.engine,
        "config",
        "env-1",
        json!({"t": "config.settings", "settings": {"wordWrap": false}}),
    );
    settings.set(&hub.engine, "autoResumeLimitedThreads", json!(true));
    answer_on(&hub, "env-1", WRITE, Ok(json!({"version": 2})));
    // The read answered late, with what it saw before the save.
    answer_on(
        &hub,
        "env-1",
        READ,
        Ok(json!({"settings": {}, "version": 1})),
    );
    assert_eq!(settings.version(), 2);
    assert_eq!(
        settings.setting(&hub.engine, "autoResumeLimitedThreads"),
        Some(json!(true))
    );
}

#[test]
fn a_change_before_the_document_is_read_is_refused() {
    let hub = Hub::new();
    let settings = Settings::of(&hub.engine);
    settings.set(&hub.engine, "autoResumeLimitedThreads", json!(true));
    assert_eq!(count(&hub, WRITE), 0);
    assert_eq!(settings.error(), NOT_LOADED);
    assert_eq!(
        toasts(&hub),
        [("Setting not saved".to_owned(), NOT_LOADED.to_owned())]
    );
}

#[test]
fn a_dropped_connection_unloads_until_the_next_read() {
    let hub = Hub::new();
    let settings = Settings::of(&hub.engine);
    hub.mc.set_ready(&hub.engine, true);
    load(&hub, json!({}), 3);
    hub.mc.set_ready(&hub.engine, false);
    assert!(!settings.ready());
    // An answer asked before the drop is not the restarted MC's.
    hub.mc.set_ready(&hub.engine, true);
    assert!(!settings.ready());
    load(&hub, json!({"wordWrap": false}), 1);
    assert!(settings.ready());
    assert_eq!(settings.version(), 1);
}

#[test]
fn pushed_keybindings_and_themes_are_told() {
    let hub = Hub::new();
    let settings = Settings::of(&hub.engine);
    let pushed = Rc::new(Cell::new(0));
    let themes = Rc::new(Cell::new(0));
    let (p, t) = (pushed.clone(), themes.clone());
    settings.on_keybindings_pushed(move |_| p.set(p.get() + 1));
    settings.on_themes_changed(move |_| t.set(t.get() + 1));
    load(&hub, json!({}), 1);
    // The snapshot's rules are not a push.
    assert_eq!(pushed.get(), 0);
    let rules = json!([{"key": "mod+k", "command": "commandPalette.toggle"}]);
    hub.mc.frame(
        &hub.engine,
        "config",
        "env-1",
        json!({"t": "config.keybindings", "rules": rules}),
    );
    assert_eq!(pushed.get(), 1);
    assert_eq!(settings.config()["keybindingRules"], rules);
    let theme = json!([{"id": "dusk"}]);
    hub.mc.frame(
        &hub.engine,
        "config",
        "env-1",
        json!({"t": "config.themes", "themes": theme}),
    );
    hub.mc.frame(
        &hub.engine,
        "config",
        "env-1",
        json!({"t": "config.themes", "themes": theme}),
    );
    assert_eq!(themes.get(), 1);
    assert_eq!(object(&hub, "themes"), theme);
}

#[test]
fn a_device_preference_is_saved_on_this_device_only() {
    let dir = config_dir("device-saved");
    let hub = with_config(&dir);
    let settings = Settings::of(&hub.engine);
    load(&hub, json!({}), 1);
    settings.set(&hub.engine, "diffLayout", json!("split"));
    assert_eq!(count(&hub, WRITE), 0);
    let file: Json =
        serde_json::from_slice(&std::fs::read(dir.join("preferences.json")).unwrap()).unwrap();
    assert_eq!(file, json!({"diffLayout": "split"}));
    assert_eq!(
        settings.setting(&hub.engine, "diffLayout"),
        Some(json!("split"))
    );
    assert_eq!(object(&hub, "device"), json!({"diffLayout": "split"}));
    // Read again by the next launch.
    let again = with_config(&dir);
    assert_eq!(
        Settings::of(&again.engine).device_value("diffLayout"),
        Some(json!("split"))
    );
    // Back to its default: gone from the file.
    settings.reset(&hub.engine, "diffLayout");
    let file: Json =
        serde_json::from_slice(&std::fs::read(dir.join("preferences.json")).unwrap()).unwrap();
    assert_eq!(file, json!({}));
}

#[test]
fn a_damaged_preferences_file_is_kept_and_nothing_is_saved_over_it() {
    let dir = config_dir("device-damaged");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("preferences.json"), "[1, 2").unwrap();
    let hub = with_config(&dir);
    let settings = Settings::of(&hub.engine);
    let reason = format!("Cannot read {}", dir.join("preferences.json").display());
    assert!(settings.device_unreadable());
    assert_eq!(settings.device_error(), reason);
    assert!(!settings.write_device(&hub.engine, "diffLayout", json!("split")));
    assert_eq!(
        std::fs::read_to_string(dir.join("preferences.json")).unwrap(),
        "[1, 2"
    );
    assert_eq!(toasts(&hub), [("Setting not saved".to_owned(), reason)]);
    // Repaired by hand and read again.
    std::fs::write(dir.join("preferences.json"), "{\"wordWrap\": false}").unwrap();
    settings.reload_device(&hub.engine);
    assert_eq!(settings.device_error(), "");
    assert_eq!(
        settings.setting(&hub.engine, "wordWrap"),
        Some(json!(false))
    );
}

#[test]
fn a_shell_without_a_config_dir_has_nowhere_to_keep_preferences() {
    let hub = Hub::new();
    let settings = Settings::of(&hub.engine);
    assert_eq!(settings.device_error(), "");
    assert!(!settings.write_device(&hub.engine, "diffLayout", json!("split")));
    assert_eq!(settings.device_error(), NOWHERE);
    assert_eq!(settings.device_value("diffLayout"), None);
}

#[test]
fn resetting_rows_together_saves_each_store_once() {
    let dir = config_dir("reset-all");
    let hub = with_config(&dir);
    let settings = Settings::of(&hub.engine);
    load(
        &hub,
        json!({"autoResumeLimitedThreads": true, "kept": 1}),
        1,
    );
    settings.set(&hub.engine, "diffLayout", json!("split"));
    settings.set(&hub.engine, "wordWrap", json!(false));
    settings.reset_all(
        &hub.engine,
        &[
            "diffLayout".into(),
            "wordWrap".into(),
            "autoResumeLimitedThreads".into(),
            "nope".into(),
        ],
    );
    assert!(settings.device().is_empty());
    assert_eq!(count(&hub, WRITE), 1);
    assert_eq!(
        last(&hub, "env-1", WRITE),
        json!({"settings": {"kept": 1}, "version": 1})
    );
}

// -- The scope --------------------------------------------------------------

struct Cluster {
    build_box_online: Rc<Cell<bool>>,
}

/// "Laptop" (this MC's env-1) and "Build box" (env-2); "hal-c2" has a
/// checkout on each, "shop" only on the laptop.
fn cluster(hub: &Hub) -> Cluster {
    let build_box_online = Rc::new(Cell::new(true));
    let online = build_box_online.clone();
    hub.mc.set_ready(&hub.engine, true);
    SettingsScope::of(&hub.engine).set_sources(
        &hub.engine,
        Rc::new(move |_| {
            vec![
                Environment {
                    id: "env-2".into(),
                    label: "Build box".into(),
                    online: online.get(),
                },
                Environment {
                    id: "env-1".into(),
                    label: "Laptop".into(),
                    online: true,
                },
            ]
        }),
        Rc::new(|_| {
            vec![
                ProjectGroup {
                    key: "hal-c2".into(),
                    title: "hal-c2".into(),
                    member_keys: vec!["env-1:p1".into(), "env-2:p9".into()],
                    members: vec![("env-1".into(), "p1".into()), ("env-2".into(), "p9".into())],
                },
                ProjectGroup {
                    key: "shop".into(),
                    title: "shop".into(),
                    member_keys: vec!["env-1:p2".into()],
                    members: vec![("env-1".into(), "p2".into())],
                },
            ]
        }),
    );
    Cluster { build_box_online }
}

/// What each environment's `config` shape says first. The laptop's frame
/// also reaches the shell's own subscription, whose read is answered.
fn documents(hub: &Hub, laptop: Json, build_box: Json) {
    let own = json!({"settings": laptop, "version": 1});
    for (environment, settings) in [("env-1", laptop), ("env-2", build_box)] {
        hub.mc.frame(
            &hub.engine,
            "config",
            environment,
            json!({"t": "config", "config": {"settings": settings,
                "environment": {"capabilities": {"projectOverrides": environment == "env-1"}}}}),
        );
    }
    answer_on(hub, "env-1", READ, Ok(own));
}

#[test]
fn the_page_states_the_project_and_environment_being_edited() {
    let hub = Hub::new();
    cluster(&hub);
    let scope = hub.published("settingsScope");
    assert_eq!(scope["kind"], "all");
    assert_eq!(scope["projectLabel"], "All projects");
    assert_eq!(scope["environmentLabel"], "All environments");
    assert_eq!(scope["connective"], "across");
    // This machine first, the others by name.
    assert_eq!(
        scope["environments"],
        json!([{"id": "env-1", "label": "Laptop", "online": true},
               {"id": "env-2", "label": "Build box", "online": true}])
    );
    assert_eq!(
        scope["projects"],
        json!([{"key": "hal-c2", "title": "hal-c2"}, {"key": "shop", "title": "shop"}])
    );
    // Not on a settings page: nothing followed.
    assert!(SettingsScope::of(&hub.engine).targets().is_empty());
    hub.dispatch("settings.open", json!({}));
    assert_eq!(SettingsScope::of(&hub.engine).targets(), ["env-1", "env-2"]);
    // A device-only section follows nothing.
    hub.dispatch("settings.navigate", json!({"to": "/settings/appearance"}));
    assert!(SettingsScope::of(&hub.engine).targets().is_empty());
}

#[test]
fn changing_one_axis_of_the_scope_keeps_the_other() {
    let hub = Hub::new();
    cluster(&hub);
    hub.dispatch("settings.open", json!({}));
    hub.dispatch("settingsScope.project", json!({"key": "hal-c2"}));
    hub.dispatch("settingsScope.environment", json!({"id": "env-1"}));
    let scope = hub.published("settingsScope");
    assert_eq!(
        (
            &scope["kind"],
            &scope["projectLabel"],
            &scope["environmentLabel"],
            &scope["connective"]
        ),
        (
            &json!("project"),
            &json!("hal-c2"),
            &json!("Laptop"),
            &json!("on")
        )
    );
    hub.dispatch("settingsScope.environment", json!({"id": "env-2"}));
    assert_eq!(hub.published("settingsScope")["projectKey"], "hal-c2");
    assert_eq!(SettingsScope::of(&hub.engine).project_on("env-2"), "p9");
    hub.dispatch("settingsScope.environment", json!({"id": ""}));
    assert_eq!(SettingsScope::of(&hub.engine).targets(), ["env-1", "env-2"]);
    hub.dispatch("settingsScope.project", json!({"key": ""}));
    hub.dispatch("settingsScope.environment", json!({"id": "env-1"}));
    let scope = hub.published("settingsScope");
    assert_eq!(
        (&scope["kind"], &scope["environmentId"]),
        (&json!("environment"), &json!("env-1"))
    );
}

#[test]
fn a_scope_that_no_longer_exists_says_why_and_saves_nothing() {
    let hub = Hub::new();
    cluster(&hub);
    hub.dispatch("settings.open", json!({}));
    hub.dispatch("settingsScope.project", json!({"key": "gone"}));
    let scope = hub.published("settingsScope");
    assert_eq!(scope["kind"], "unavailable");
    assert_eq!(scope["projectLabel"], "Unavailable project");
    assert_eq!(
        scope["disabledReason"],
        "This project is no longer available."
    );
    hub.dispatch("settingsScope.project", json!({"key": "shop"}));
    hub.dispatch("settingsScope.environment", json!({"id": "env-2"}));
    assert_eq!(
        hub.published("settingsScope")["message"],
        "This project has no checkout on this environment."
    );
    hub.dispatch("settingsScope.project", json!({"key": ""}));
    hub.dispatch("settingsScope.environment", json!({"id": "env-9"}));
    let scope = hub.published("settingsScope");
    assert_eq!(scope["environmentLabel"], "Unavailable environment");
    assert_eq!(scope["editable"], false);
    let writes = count(&hub, WRITE) + count(&hub, READ);
    SettingsScope::of(&hub.engine).write(&hub.engine, |s, _| s, "");
    assert_eq!(count(&hub, WRITE) + count(&hub, READ), writes);
    assert_eq!(
        toasts(&hub),
        [(
            "Setting not saved".to_owned(),
            "This environment is no longer available.".to_owned()
        )]
    );
}

#[test]
fn an_environment_wide_change_is_saved_on_every_connected_environment() {
    let hub = Hub::new();
    cluster(&hub);
    load(&hub, json!({}), 1);
    hub.dispatch("settings.open", json!({}));
    documents(&hub, json!({"wordWrap": true}), json!({"wordWrap": false}));
    let settings = Settings::of(&hub.engine);
    // The first target's value shows, and the others differ.
    assert_eq!(
        settings.setting(&hub.engine, "autoResumeLimitedThreads"),
        Some(json!(false))
    );
    settings.set(&hub.engine, "autoResumeLimitedThreads", json!(true));
    answer_on(
        &hub,
        "env-1",
        READ,
        Ok(json!({"settings": {"a": 1}, "version": 3})),
    );
    answer_on(
        &hub,
        "env-2",
        READ,
        Ok(json!({"settings": {}, "version": 8})),
    );
    assert_eq!(
        last(&hub, "env-1", WRITE),
        json!({"settings": {"a": 1, "autoResumeLimitedThreads": true}, "version": 3})
    );
    assert_eq!(
        last(&hub, "env-2", WRITE),
        json!({"settings": {"autoResumeLimitedThreads": true}, "version": 8})
    );
}

#[test]
fn a_value_that_differs_between_environments_shows_as_mixed() {
    let hub = Hub::new();
    cluster(&hub);
    hub.dispatch("settings.open", json!({}));
    documents(&hub, json!({"autoResumeLimitedThreads": true}), json!({}));
    let settings = Settings::of(&hub.engine);
    assert!(settings.mixed(&hub.engine, "autoResumeLimitedThreads"));
    assert!(!settings.is_default(&hub.engine, "autoResumeLimitedThreads"));
    assert_eq!(
        settings.setting(&hub.engine, "autoResumeLimitedThreads"),
        Some(json!(true))
    );
    // Device rows never are.
    assert!(!settings.mixed(&hub.engine, "wordWrap"));
}

#[test]
fn saving_on_some_environments_but_not_others_is_reported() {
    let hub = Hub::new();
    cluster(&hub);
    hub.dispatch("settings.open", json!({}));
    documents(&hub, json!({}), json!({}));
    Settings::of(&hub.engine).set(&hub.engine, "autoResumeLimitedThreads", json!(true));
    answer_on(
        &hub,
        "env-1",
        READ,
        Ok(json!({"settings": {}, "version": 1})),
    );
    answer_on(&hub, "env-2", READ, Err(McError::new("disk full")));
    answer_on(&hub, "env-1", WRITE, Ok(json!({"version": 2})));
    assert_eq!(
        toasts(&hub),
        [(
            "Setting saved on some environments".to_owned(),
            "Could not update Build box. The other selected environments saved the change."
                .to_owned()
        )]
    );
}

#[test]
fn a_setting_cannot_be_changed_while_its_environment_is_disconnected() {
    let hub = Hub::new();
    let cluster = cluster(&hub);
    hub.dispatch("settings.open", json!({}));
    hub.dispatch("settingsScope.environment", json!({"id": "env-2"}));
    cluster.build_box_online.set(false);
    SettingsScope::of(&hub.engine).refresh(&hub.engine);
    let settings = Settings::of(&hub.engine);
    let scope = hub.published("settingsScope");
    assert_eq!(scope["environments"][1]["online"], false);
    assert_eq!(scope["disabledReason"], RECONNECT);
    assert_eq!(settings.unreachable(&hub.engine), ["Build box"]);
    // No target, so the row reads this MC's document and saves nothing.
    assert_eq!(
        settings.disabled_reason(&hub.engine, "autoResumeLimitedThreads"),
        ""
    );
    assert!(!settings.supports(&hub.engine, "projectOverrides"));
}

#[test]
fn a_project_change_is_saved_as_an_override_and_a_reset_inherits_again() {
    let hub = Hub::new();
    cluster(&hub);
    hub.dispatch("settings.open", json!({}));
    hub.dispatch("settingsScope.project", json!({"key": "hal-c2"}));
    documents(
        &hub,
        json!({"responseStreamingMode": "full"}),
        json!({"projectSettingsOverrides": {"p9": {"responseStreamingMode": "off"}}}),
    );
    let settings = Settings::of(&hub.engine);
    assert_eq!(
        settings.disabled_reason(&hub.engine, "autoResumeLimitedThreads"),
        ENVIRONMENT_WIDE
    );
    assert_eq!(
        settings.setting(&hub.engine, "responseStreamingMode"),
        Some(json!("full"))
    );
    assert!(settings.mixed(&hub.engine, "responseStreamingMode"));
    // Only the laptop has the capability.
    assert!(!settings.supports(&hub.engine, "projectOverrides"));
    settings.set(&hub.engine, "responseStreamingMode", json!("paragraph"));
    answer_on(
        &hub,
        "env-1",
        READ,
        Ok(json!({"settings": {"responseStreamingMode": "full"}, "version": 1})),
    );
    answer_on(
        &hub,
        "env-2",
        READ,
        Ok(json!({"settings": {}, "version": 1})),
    );
    assert_eq!(
        last(&hub, "env-1", WRITE)["settings"],
        json!({"responseStreamingMode": "full",
               "projectSettingsOverrides": {"p1": {"responseStreamingMode": "paragraph"}}})
    );
    assert_eq!(
        last(&hub, "env-2", WRITE)["settings"],
        json!({"projectSettingsOverrides": {"p9": {"responseStreamingMode": "paragraph"}}})
    );
    settings.reset(&hub.engine, "responseStreamingMode");
    answer_on(
        &hub,
        "env-2",
        READ,
        Ok(
            json!({"settings": {"projectSettingsOverrides": {"p9": {"responseStreamingMode": "off"}}}, "version": 2}),
        ),
    );
    assert_eq!(
        last(&hub, "env-2", WRITE)["settings"],
        json!({"projectSettingsOverrides": {}})
    );
}

#[test]
fn the_picked_project_follows_its_checkouts_to_a_new_key() {
    let hub = Hub::new();
    cluster(&hub);
    hub.dispatch("settings.open", json!({}));
    hub.dispatch("settingsScope.project", json!({"key": "shop"}));
    // Regrouped: shop's checkout is now under another key.
    SettingsScope::of(&hub.engine).set_sources(
        &hub.engine,
        Rc::new(|_| {
            vec![Environment {
                id: "env-1".into(),
                label: "Laptop".into(),
                online: true,
            }]
        }),
        Rc::new(|_| {
            vec![ProjectGroup {
                key: "repo:shop".into(),
                title: "shop".into(),
                member_keys: vec!["env-1:p2".into()],
                members: vec![("env-1".into(), "p2".into())],
            }]
        }),
    );
    let scope = hub.published("settingsScope");
    assert_eq!(
        (&scope["projectKey"], &scope["kind"]),
        (&json!("repo:shop"), &json!("project"))
    );
}

// -- The model ----------------------------------------------------------------

/// What another editor or this shell does to the MC's document, in any
/// order; the MC answers calls when the test says.
#[derive(Clone, Debug)]
enum Op {
    /// Another client saves; the MC pushes `config.settings`.
    Elsewhere(u8, u8),
    /// This shell changes a key.
    Change(u8, u8),
    /// The MC answers the oldest unanswered read or write.
    AnswerRead,
    AnswerWrite,
    /// A device preference.
    Device(u8),
    /// The connection drops and comes back.
    Reconnect,
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        2 => (0u8..3, 0u8..4).prop_map(|(k, v)| Op::Elsewhere(k, v)),
        3 => (0u8..3, 0u8..4).prop_map(|(k, v)| Op::Change(k, v)),
        4 => Just(Op::AnswerRead),
        4 => Just(Op::AnswerWrite),
        1 => (0u8..3).prop_map(Op::Device),
        1 => Just(Op::Reconnect),
    ]
}

/// The MC as the model has it: one document and its version; a write at
/// another version is stale.
struct Server {
    document: Map,
    version: i64,
}

struct World {
    hub: Hub,
    dir: PathBuf,
    server: Server,
    /// Each change's outcomes so far, by change.
    done: Rc<RefCell<Vec<u32>>>,
    device: Map,
}

impl World {
    fn new(case: usize) -> World {
        let dir = config_dir(&format!("model-{case}"));
        let hub = with_config(&dir);
        hub.mc.set_ready(&hub.engine, true);
        let mut world = World {
            hub,
            dir,
            server: Server {
                document: Map::new(),
                version: 1,
            },
            done: Rc::default(),
            device: Map::new(),
        };
        world.snapshot();
        world
    }

    fn snapshot(&mut self) {
        self.hub.mc.frame(
            &self.hub.engine,
            "config",
            "env-1",
            json!({"t": "config", "config": {"settings": self.server.document}}),
        );
    }

    fn answer(&mut self, method: &str) {
        let Some(index) = self.hub.mc.pending(method) else {
            return;
        };
        let payload = self.hub.mc.calls.borrow()[index].2.clone();
        let result = if method == READ {
            Ok(json!({"settings": self.server.document, "version": self.server.version}))
        } else if payload["version"] == json!(self.server.version) {
            self.server.document = map(payload["settings"].clone());
            self.server.version += 1;
            Ok(json!({"version": self.server.version}))
        } else {
            Err(stale())
        };
        self.hub.mc.reply(&self.hub.engine, index, result);
    }

    fn step(&mut self, op: Op) {
        let engine = &self.hub.engine;
        match op {
            Op::Elsewhere(k, v) => {
                self.server.document.insert(format!("k{k}"), json!(v));
                self.server.version += 1;
                self.hub.mc.frame(
                    engine,
                    "config",
                    "env-1",
                    json!({"t": "config.settings", "settings": self.server.document}),
                );
            }
            Op::Change(k, v) => {
                let index = {
                    let mut done = self.done.borrow_mut();
                    done.push(0);
                    done.len() - 1
                };
                let done = self.done.clone();
                Settings::of(engine).change(
                    engine,
                    move |s| {
                        let mut s = s.clone();
                        s.insert(format!("k{k}"), json!(v));
                        s
                    },
                    move |_, _| done.borrow_mut()[index] += 1,
                );
            }
            Op::AnswerRead => self.answer(READ),
            Op::AnswerWrite => self.answer(WRITE),
            Op::Device(v) => {
                let value = if v == 0 { Json::Null } else { json!(v) };
                assert!(Settings::of(engine).write_device(engine, "deviceKey", value.clone()));
                if value.is_null() {
                    self.device.remove("deviceKey");
                } else {
                    self.device.insert("deviceKey".into(), value);
                }
            }
            Op::Reconnect => {
                self.hub.mc.set_ready(engine, false);
                assert!(!Settings::of(engine).ready());
                self.hub.mc.set_ready(engine, true);
                assert!(!Settings::of(engine).ready());
                self.snapshot();
            }
        }
    }

    /// Answers everything, then the snapshot a resubscription brings.
    fn settle(&mut self) {
        while self.hub.mc.pending(READ).is_some() || self.hub.mc.pending(WRITE).is_some() {
            self.answer(READ);
            self.answer(WRITE);
        }
        self.snapshot();
        self.answer(READ);
    }
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 128, ..ProptestConfig::default() })]

    #[test]
    fn settings_converge_on_the_mcs_document(ops in proptest::collection::vec(op(), 1..40)) {
        static CASE: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let mut world = World::new(CASE.fetch_add(1, std::sync::atomic::Ordering::Relaxed));
        for op in ops {
            world.step(op);
        }
        world.settle();
        let settings = Settings::of(&world.hub.engine);
        prop_assert!(settings.ready());
        prop_assert_eq!(settings.settings(), world.server.document.clone());
        prop_assert_eq!(settings.version(), world.server.version);
        // Every change was told how it went, once.
        prop_assert!(world.done.borrow().iter().all(|n| *n == 1), "{:?}", world.done.borrow());
        prop_assert_eq!(settings.device(), world.device.clone());
        if !world.device.is_empty() {
            let file: Json = serde_json::from_slice(
                &std::fs::read(world.dir.join("preferences.json")).unwrap(),
            )
            .unwrap();
            prop_assert_eq!(file, Json::Object(world.device.clone()));
        }
    }
}
