//! `projectActions`: adding, editing and deleting a project's actions, their
//! shortcuts and hal-c2.json, and the same list as Settings → Project keeps
//! it (ProjectActionsController.cpp, features/projects/scripts.feature).

use hal_c2_shell::controllers::sidebar;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::McError;
use hal_c2_shell::project::place::{self, Place};
use serde_json::json;

use crate::Hub;

const AT: &str = "2026-03-01T00:00:00Z";
const MUTATE: &str = "projects.mutate";
const READ: &str = "hal-c2.readSettings";
const WRITE: &str = "hal-c2.writeSettings";
const UPSERT: &str = "hal-c2.upsertKeybinding";
const REMOVE: &str = "hal-c2.removeKeybinding";

fn test_script() -> Json {
    json!({"id": "test", "name": "Test", "command": "bun test", "icon": "test",
        "runOnWorktreeCreate": false})
}

fn setup_script() -> Json {
    json!({"id": "setup", "name": "Setup", "command": "bun i", "icon": "configure",
        "runOnWorktreeCreate": true})
}

/// The environment's config frame, and the reads it sets off answered with
/// the same settings.
fn config(hub: &Hub, settings: Json) {
    hub.mc.frame(
        &hub.engine,
        "config",
        "env-1",
        json!({"t": "config", "config": {"settings": settings,
            "environment": {"capabilities": {"projectSettingsOverrides": true}}}}),
    );
    while let Some(index) = hub.mc.pending_on("env-1", READ) {
        hub.mc.reply(
            &hub.engine,
            index,
            Ok(json!({"settings": settings, "version": 1})),
        );
    }
}

/// `env-1` with project `p1` (rows carrying `scripts`), the route on its
/// thread, hal-c2.json read as `file`, and the environment's `settings`.
fn hub(scripts: Vec<Json>, file: Option<&str>, settings: Json) -> Hub {
    let hub = Hub::clustered();
    hub.mc.set_ready(&hub.engine, true);
    rows(&hub, &scripts);
    place::set_place(
        &hub.engine,
        Some(Place {
            environment_id: "env-1".into(),
            thread_id: "t1".into(),
            project_id: "p1".into(),
            root: "/w/p1".into(),
            scripts,
            ..Place::default()
        }),
    );
    hub.advance(0);
    config(&hub, settings);
    match file {
        Some(contents) => hub.mc.answer(
            &hub.engine,
            "projects.readFile",
            Ok(json!({"contents": contents})),
        ),
        None => hub.mc.answer(
            &hub.engine,
            "projects.readFile",
            Err(McError::new("no such file")),
        ),
    }
    hub
}

/// The shell's rows: `p1` with `scripts`, and `p2` with one of its own.
fn rows(hub: &Hub, scripts: &[Json]) {
    let project = |id: &str, scripts: &[Json]| {
        json!(["a", id, "project", {"id": id, "title": id, "workspaceRoot": format!("/w/{id}"),
            "scripts": scripts, "createdAt": AT, "updatedAt": AT}])
    };
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell", "mcs": [{"mc": "a", "online": true, "epoch": "e", "rev": 1,
            "environment": {"environmentId": "env-1", "label": "Laptop",
                "capabilities": {"projectSettingsOverrides": true}}}],
            "rows": [project("p1", scripts),
                project("p2", &[json!({"id": "deploy", "name": "Deploy", "command": "make",
                    "icon": "play", "runOnWorktreeCreate": false})])]}),
    );
}

fn state(hub: &Hub) -> Json {
    hub.published("projectActions")
}

fn editor(hub: &Hub) -> Json {
    state(hub)["editor"].clone()
}

fn set(hub: &Hub, fields: Json) {
    hub.dispatch("projectActions.set", fields);
}

fn mutation(hub: &Hub) -> Json {
    let index = hub.mc.pending(MUTATE).expect("a project update was sent");
    hub.mc.calls.borrow()[index].2.clone()
}

fn bindings(hub: &Hub, rules: Json) {
    hub.mc.frame(
        &hub.engine,
        "config",
        "env-1",
        json!({"t": "config.keybindings", "rules": rules}),
    );
}

fn ids(scripts: &Json) -> Vec<String> {
    scripts
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["id"].as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn away_from_a_project_there_are_no_actions_and_the_palette_command_waits() {
    let hub = Hub::clustered();
    assert_eq!(state(&hub), Json::Null);
    hub.dispatch("projectActions.add", json!({}));
    assert_eq!(state(&hub), Json::Null);
}

#[test]
fn the_project_shows_its_actions_and_what_its_file_offers_beyond_them() {
    let file = r#"{"scripts": [
        {"name": "Test", "command": "bun test"},
        {"name": "Lint", "command": "bun lint", "icon": "lint"},
        {"name": "deploy", "command": "make deploy"}]}"#;
    let hub = hub(vec![test_script()], Some(file), json!({}));
    let shown = state(&hub);
    assert_eq!(shown["projectKey"], "env-1:p1");
    assert_eq!(shown["file"], "valid");
    assert_eq!(ids(&shown["scripts"]), ["test"]);
    assert_eq!(shown["scripts"][0]["shortcut"], "");
    // Test is listed already (by command); the others are offered.
    assert_eq!(
        shown["imports"],
        json!([
            {"name": "Lint", "command": "bun lint", "icon": "lint"},
            {"name": "deploy", "command": "make deploy", "icon": "play"},
        ])
    );
}

#[test]
fn a_file_that_is_missing_or_does_not_parse_says_so() {
    let hub = hub(vec![], None, json!({}));
    assert_eq!(state(&hub)["file"], "missing");
    let hub = self::hub(vec![], Some("{\"scripts\": 3}"), json!({}));
    assert_eq!(state(&hub)["file"], "invalid");
    assert_eq!(state(&hub)["imports"], json!([]));
}

#[test]
fn a_new_action_needs_a_name_and_a_command_and_gets_an_id_from_its_name() {
    let hub = hub(vec![test_script()], None, json!({}));
    hub.dispatch("projectActions.add", json!({}));
    assert_eq!(editor(&hub)["icon"], "play");
    assert_eq!(editor(&hub)["scriptId"], "");
    hub.dispatch("projectActions.save", json!({}));
    assert_eq!(editor(&hub)["error"], "Name is required.");
    set(&hub, json!({"name": " Test "}));
    assert_eq!(editor(&hub)["error"], "");
    hub.dispatch("projectActions.save", json!({}));
    assert_eq!(editor(&hub)["error"], "Command is required.");
    set(
        &hub,
        json!({"command": " bun test --watch ", "keybinding": "not a key +"}),
    );
    hub.dispatch("projectActions.save", json!({}));
    assert_eq!(editor(&hub)["error"], "Invalid keybinding.");
    assert!(hub.mc.pending(MUTATE).is_none());

    set(&hub, json!({"keybinding": "", "icon": "party"}));
    // Not one of the icons: unchanged.
    assert_eq!(editor(&hub)["icon"], "play");
    set(&hub, json!({"icon": "debug"}));
    hub.dispatch("projectActions.save", json!({}));
    assert_eq!(editor(&hub)["saving"], true);
    let sent = mutation(&hub);
    assert_eq!(sent["type"], "project.update");
    assert_eq!(sent["projectId"], "p1");
    // "test" is taken in this environment.
    assert_eq!(ids(&sent["scripts"]), ["test", "test-2"]);
    assert_eq!(sent["scripts"][1]["command"], "bun test --watch");
    assert_eq!(sent["scripts"][1]["icon"], "debug");
    // Not edited while it saves.
    set(&hub, json!({"name": "other"}));
    assert_eq!(editor(&hub)["name"], " Test ");
    hub.mc.answer(&hub.engine, MUTATE, Ok(json!({})));
    assert_eq!(editor(&hub), Json::Null);
}

#[test]
fn a_save_the_mc_refuses_keeps_the_editor_with_the_reason() {
    let hub = hub(vec![], None, json!({}));
    hub.dispatch("projectActions.add", json!({}));
    set(&hub, json!({"name": "Build", "command": "make"}));
    hub.dispatch("projectActions.save", json!({}));
    hub.mc.answer(&hub.engine, MUTATE, Err(McError::new("")));
    assert_eq!(editor(&hub)["error"], "Failed to save action.");
    assert_eq!(editor(&hub)["saving"], false);
    // The reason stays until a field changes.
    hub.dispatch("projectActions.save", json!({}));
    assert!(hub.mc.pending(MUTATE).is_none());
    set(&hub, json!({"command": "make all"}));
    assert_eq!(editor(&hub)["error"], "");
    hub.dispatch("projectActions.save", json!({}));
    hub.mc
        .answer(&hub.engine, MUTATE, Err(McError::new("read-only")));
    assert_eq!(editor(&hub)["error"], "read-only");
    hub.dispatch("projectActions.cancel", json!({}));
    assert_eq!(editor(&hub), Json::Null);
}

#[test]
fn one_action_is_the_setup_script_and_waiting_for_it_needs_setup() {
    let hub = hub(vec![setup_script(), test_script()], None, json!({}));
    hub.dispatch("projectActions.edit", json!({"scriptId": "test"}));
    set(&hub, json!({"waitForSetup": true}));
    // Waiting is for setup scripts.
    assert_eq!(editor(&hub)["waitForSetup"], false);
    set(
        &hub,
        json!({"runOnWorktreeCreate": true, "waitForSetup": true}),
    );
    assert_eq!(editor(&hub)["waitForSetup"], true);
    set(
        &hub,
        json!({"previewUrl": "http://localhost:3000", "autoOpenPreview": true}),
    );
    assert_eq!(editor(&hub)["canAutoOpenPreview"], true);
    set(&hub, json!({"previewUrl": " "}));
    assert_eq!(editor(&hub)["autoOpenPreview"], false);
    set(
        &hub,
        json!({"previewUrl": "http://localhost:3000", "autoOpenPreview": true}),
    );
    hub.dispatch("projectActions.save", json!({}));
    let sent = mutation(&hub);
    assert_eq!(ids(&sent["scripts"]), ["setup", "test"]);
    assert_eq!(sent["scripts"][0]["runOnWorktreeCreate"], false);
    assert_eq!(sent["scripts"][1]["runOnWorktreeCreate"], true);
    assert_eq!(sent["scripts"][1]["async"], false);
    assert_eq!(sent["scripts"][1]["previewUrl"], "http://localhost:3000");
    assert_eq!(sent["scripts"][1]["autoOpenPreview"], true);
}

#[test]
fn an_action_edit_loads_what_it_has_and_a_shortcut_moves_with_it() {
    let hub = hub(vec![test_script()], None, json!({}));
    bindings(
        &hub,
        json!([{"key": "mod+j", "command": "script.test.run"}]),
    );
    assert_ne!(state(&hub)["scripts"][0]["shortcut"], "");
    hub.dispatch("projectActions.edit", json!({"scriptId": "nope"}));
    assert_eq!(editor(&hub), Json::Null);
    hub.dispatch("projectActions.edit", json!({"scriptId": "test"}));
    let loaded = editor(&hub);
    assert_eq!(loaded["name"], "Test");
    assert_eq!(loaded["scriptId"], "test");
    assert_eq!(loaded["keybinding"], "mod+j");
    set(&hub, json!({"keybinding": "mod+k"}));
    hub.dispatch("projectActions.save", json!({}));
    hub.mc.answer(&hub.engine, MUTATE, Ok(json!({})));
    let index = hub.mc.pending(UPSERT).expect("the shortcut moves");
    assert_eq!(
        hub.mc.calls.borrow()[index].2,
        json!({"key": "mod+k", "command": "script.test.run",
            "replace": {"key": "mod+j", "command": "script.test.run"}})
    );
}

#[test]
fn deleting_asks_first_and_takes_the_shortcut_unless_another_project_uses_the_id() {
    let hub = hub(vec![test_script()], None, json!({}));
    bindings(
        &hub,
        json!([{"key": "mod+j", "command": "script.test.run"}]),
    );
    hub.dispatch("projectActions.delete", json!({"scriptId": "test"}));
    let question = hub.published("confirmation");
    assert_eq!(question["title"], "Delete action \"Test\"?");
    assert_eq!(question["description"], "This action cannot be undone.");
    assert_eq!(question["confirmLabel"], "Delete action");
    assert_eq!(question["destructive"], true);
    assert!(hub.mc.pending(MUTATE).is_none());
    hub.dispatch(
        "confirmation.answer",
        json!({"requestId": question["requestId"], "accepted": true}),
    );
    assert_eq!(mutation(&hub)["scripts"], json!([]));
    hub.mc.answer(&hub.engine, MUTATE, Ok(json!({})));
    let index = hub.mc.pending(REMOVE).expect("the shortcut goes");
    assert_eq!(
        hub.mc.calls.borrow()[index].2,
        json!({"key": "mod+j", "command": "script.test.run"})
    );
}

#[test]
fn a_shortcut_stays_while_another_project_still_has_an_action_of_that_id() {
    let twin = json!({"id": "deploy", "name": "Deploy", "command": "make", "icon": "play",
        "runOnWorktreeCreate": false});
    let hub = hub(vec![twin], None, json!({}));
    bindings(
        &hub,
        json!([{"key": "mod+j", "command": "script.deploy.run"}]),
    );
    hub.dispatch("projectActions.delete", json!({"scriptId": "deploy"}));
    let question = hub.published("confirmation");
    hub.dispatch(
        "confirmation.answer",
        json!({"requestId": question["requestId"], "accepted": true}),
    );
    hub.mc.answer(&hub.engine, MUTATE, Ok(json!({})));
    assert!(hub.mc.pending(REMOVE).is_none());
}

#[test]
fn importing_adds_the_files_actions_keeping_the_one_setup_script() {
    let file = r#"{"scripts": [
        {"name": "Install", "command": "bun install", "runOnWorktreeCreate": true, "async": false},
        {"name": "Lint", "command": "bun lint", "icon": "lint", "previewUrl": "http://x", "autoOpenPreview": true}]}"#;
    let hub = hub(vec![setup_script()], Some(file), json!({}));
    hub.dispatch("projectActions.import", json!({"name": "Nope"}));
    assert!(hub.mc.pending(MUTATE).is_none());
    hub.dispatch("projectActions.import", json!({}));
    let sent = mutation(&hub);
    assert_eq!(ids(&sent["scripts"]), ["setup", "install", "lint"]);
    // The project has a setup script already.
    assert_eq!(sent["scripts"][1]["runOnWorktreeCreate"], false);
    assert!(sent["scripts"][1].get("async").is_none());
    assert_eq!(sent["scripts"][2]["previewUrl"], "http://x");
    hub.mc
        .answer(&hub.engine, MUTATE, Err(McError::new("read-only")));
    assert_eq!(
        hub.published("toasts")["items"][0]["title"],
        "Failed to import action."
    );
}

#[test]
fn a_project_with_its_own_list_in_settings_keeps_changes_there() {
    let settings = json!({"projectSettingsOverrides": {"p1": {"defaultProjectScripts": []}}});
    let hub = hub(vec![], None, settings);
    hub.dispatch("projectActions.add", json!({}));
    set(&hub, json!({"name": "Build", "command": "make"}));
    hub.dispatch("projectActions.save", json!({}));
    assert!(hub.mc.pending(MUTATE).is_none());
    hub.mc.answer_on(
        &hub.engine,
        "env-1",
        READ,
        Ok(json!({"settings": {"projectSettingsOverrides": {"p1": {"defaultProjectScripts": []}}}, "version": 1})),
    );
    let index = hub.mc.pending(WRITE).expect("the override is written");
    let written = hub.mc.calls.borrow()[index].2.clone();
    assert_eq!(
        written["settings"]["projectSettingsOverrides"]["p1"]["defaultProjectScripts"][0]["id"],
        "build"
    );
    hub.mc.reply(&hub.engine, index, Ok(json!({"version": 2})));
    assert_eq!(editor(&hub), Json::Null);
}

#[test]
fn a_new_threads_workspace_comes_from_the_setting_else_the_file() {
    let draft = |id: &str| Place {
        environment_id: "env-1".into(),
        thread_id: format!("t-{id}"),
        project_id: "p1".into(),
        draft_id: id.into(),
        root: "/w/p1".into(),
        ..Place::default()
    };
    // The saved setting.
    let hub = hub(
        vec![],
        Some(r#"{"defaultThreadEnvMode": "local"}"#),
        json!({"defaultThreadEnvMode": "worktree"}),
    );
    place::set_place(&hub.engine, Some(draft("d1")));
    hub.advance(0);
    assert_eq!(place::checkout(&hub.engine, "d1").env_mode, "worktree");
    // A draft already placed by the user stays.
    place::set_checkout(
        &hub.engine,
        "d2",
        place::Checkout {
            branch: Some("main".into()),
            ..place::Checkout::default()
        },
    );
    place::set_place(&hub.engine, Some(draft("d2")));
    hub.advance(0);
    assert_eq!(place::checkout(&hub.engine, "d2").env_mode, "local");

    // Without a setting, the file.
    let hub = self::hub(
        vec![],
        Some(r#"{"defaultThreadEnvMode": "worktree"}"#),
        json!({}),
    );
    place::set_place(&hub.engine, Some(draft("d3")));
    hub.advance(0);
    // Read for this draft first.
    hub.mc.answer(
        &hub.engine,
        "projects.readFile",
        Ok(json!({"contents": r#"{"defaultThreadEnvMode": "worktree"}"#})),
    );
    assert_eq!(place::checkout(&hub.engine, "d3").env_mode, "worktree");
}

// -- Settings → Project -----------------------------------------------------

fn open_settings(hub: &Hub) {
    hub.dispatch("settings.navigate", json!({"to": "/settings/projects"}));
}

fn settings_hub(settings: Json) -> Hub {
    let hub = Hub::clustered();
    hub.mc.set_ready(&hub.engine, true);
    rows(&hub, &[test_script()]);
    open_settings(&hub);
    config(&hub, settings);
    hub
}

#[test]
fn settings_without_a_project_list_the_environments_defaults_and_save_changes_there() {
    let hub = settings_hub(json!({"defaultProjectScripts": [setup_script()]}));
    let shown = state(&hub);
    assert_eq!(shown["settings"], true);
    assert_eq!(shown["project"], false);
    assert_eq!(shown["available"], true);
    assert_eq!(shown["mixed"], false);
    assert_eq!(ids(&shown["scripts"]), ["setup"]);
    assert_eq!(shown["scripts"][0]["setup"], true);
    assert_eq!(shown["scripts"][0]["preview"], false);

    hub.dispatch("projectActions.add", json!({"name": "  ", "command": "x"}));
    assert!(hub.mc.pending(READ).is_none());
    hub.dispatch(
        "projectActions.add",
        json!({"name": "Setup", "command": "bun run setup", "runOnWorktreeCreate": true}),
    );
    hub.mc.answer_on(
        &hub.engine,
        "env-1",
        READ,
        Ok(json!({"settings": {"defaultProjectScripts": [setup_script()]}, "version": 1})),
    );
    let index = hub.mc.pending(WRITE).expect("the defaults are written");
    let written = hub.mc.calls.borrow()[index].2.clone();
    let scripts = &written["settings"]["defaultProjectScripts"];
    // The id is not the taken "setup"; the new one is the only setup script.
    assert_eq!(ids(scripts), ["setup", "setup-2"]);
    assert_eq!(scripts[0]["runOnWorktreeCreate"], false);
    assert_eq!(scripts[1]["runOnWorktreeCreate"], true);

    hub.mc.reply(&hub.engine, index, Ok(json!({"version": 2})));
    hub.dispatch("projectActions.delete", json!({"scriptId": "setup"}));
    hub.mc.answer_on(
        &hub.engine,
        "env-1",
        READ,
        Ok(json!({"settings": {"defaultProjectScripts": [setup_script(), test_script()]}, "version": 2})),
    );
    let index = hub.mc.pending(WRITE).expect("the defaults are written");
    assert_eq!(
        ids(&hub.mc.calls.borrow()[index].2["settings"]["defaultProjectScripts"]),
        ["test"]
    );
}

#[test]
fn settings_for_one_project_show_its_own_list_else_the_defaults_and_reset_inherits_again() {
    let pick = |hub: &Hub| {
        let key = sidebar::groups(&hub.engine)
            .into_iter()
            .find(|g| g.members.iter().any(|m| m.id == "p1"))
            .expect("p1's group")
            .key;
        hub.dispatch("settingsScope.project", json!({"key": key}));
        key
    };
    // Folded into the defaults, the project has no list of its own: nothing
    // to reset.
    let hub = settings_hub(
        json!({"defaultProjectScripts": [setup_script()], "projectSettingsFolded": true}),
    );
    let key = pick(&hub);
    let shown = state(&hub);
    assert_eq!(shown["project"], true);
    assert_eq!(shown["projectKey"], key);
    assert_eq!(shown["own"], false);
    assert_eq!(ids(&shown["scripts"]), ["setup"]);
    hub.dispatch("projectActions.reset", json!({}));
    assert!(hub.mc.pending(WRITE).is_none());

    let overridden = json!({"defaultProjectScripts": [setup_script()],
        "projectSettingsOverrides": {"p1": {"defaultProjectScripts": [test_script()]}}});
    let hub = settings_hub(overridden.clone());
    pick(&hub);
    let shown = state(&hub);
    assert_eq!(shown["own"], true);
    assert_eq!(ids(&shown["scripts"]), ["test"]);
    hub.dispatch("projectActions.reset", json!({}));
    hub.mc.answer_on(
        &hub.engine,
        "env-1",
        READ,
        Ok(json!({"settings": overridden, "version": 1})),
    );
    let index = hub.mc.pending(WRITE).expect("the override goes");
    assert_eq!(
        hub.mc.calls.borrow()[index].2["settings"],
        json!({"defaultProjectScripts": [setup_script()], "projectSettingsOverrides": {}})
    );
}

#[test]
fn nothing_is_saved_without_a_machine_to_save_to_and_an_import_without_a_file_adds_nothing() {
    let hub = settings_hub(json!({}));
    // No project, no file: nothing to import.
    hub.dispatch("projectActions.import", json!({}));
    assert!(hub.mc.pending(READ).is_none());
    assert!(hub.mc.pending(WRITE).is_none());

    // A machine that has not answered cannot be written.
    let hub = Hub::clustered();
    rows(&hub, &[]);
    open_settings(&hub);
    hub.dispatch("projectActions.add", json!({"name": "A", "command": "b"}));
    assert_eq!(
        hub.published("toasts")["items"][0]["title"],
        "Actions not saved"
    );
}
