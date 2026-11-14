//! `projects`: opening a folder as a project, Add project's choices, and
//! removing projects after asking (ProjectController.cpp,
//! features/projects/).

use hal_c2_shell::Launch;
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::commands::Commands;
use hal_c2_shell::controllers::projects::{self, ADD};
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::McError;
use hal_c2_shell::this_machine;
use proptest::prelude::*;
use serde_json::json;

use crate::Hub;

const AT: &str = "2026-03-01T00:00:00Z";
const MUTATE: &str = "projects.mutate";

/// A hub on the same machine as its MC, `env-1` online, a place to keep
/// drafts, and the folder-open actions allowed.
fn hub() -> (Hub, tempfile::TempDir) {
    let dir = tempfile::tempdir().expect("a cache directory");
    let hub = Hub::with(Launch {
        mc_origin: Some("http://127.0.0.1:1".into()),
        cache_dir: Some(dir.path().to_owned()),
        ..Launch::default()
    });
    Bridge::of(&hub.engine).set_local_folder_import_enabled(&hub.engine, true);
    hub.mc.set_ready(&hub.engine, true);
    shell(&hub, &[]);
    (hub, dir)
}

/// `env-1` and its projects `(id, workspaceRoot)`, plus `threads`
/// `(id, project)`.
fn shell(hub: &Hub, projects: &[(&str, &str)]) {
    shell_with(hub, projects, &[]);
}

fn shell_with(hub: &Hub, projects: &[(&str, &str)], threads: &[(&str, &str)]) {
    let mut rows: Vec<Json> = projects
        .iter()
        .map(|(id, root)| {
            json!(["a", id, "project", {"id": id, "title": id, "workspaceRoot": root,
                "createdAt": AT, "updatedAt": AT}])
        })
        .collect();
    rows.extend(threads.iter().map(|(id, project)| {
        json!(["a", id, "thread", {"id": id, "projectId": project, "title": id,
            "createdAt": AT, "updatedAt": AT, "modelSelection": {"instanceId": "claude", "model": "m"}}])
    }));
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell", "mcs": [{"mc": "a", "online": true, "epoch": "e", "rev": 1,
            "environment": {"environmentId": "env-1", "label": "Laptop"}}],
            "rows": rows}),
    );
}

fn titles(hub: &Hub) -> Vec<String> {
    hub.published("toasts")["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["title"].as_str().unwrap().to_owned())
        .collect()
}

fn folder() -> (tempfile::TempDir, String) {
    let dir = tempfile::tempdir().expect("a folder to open");
    let path = std::fs::canonicalize(dir.path()).unwrap();
    (dir, path.to_string_lossy().into_owned())
}

#[test]
fn a_folder_that_is_not_one_opens_nothing() {
    let (hub, _dir) = hub();
    hub.dispatch("project.folder.open", json!({"path": "/no/such/folder"}));
    assert_eq!(titles(&hub), ["Could not open folder"]);
    assert!(hub.mc.pending(MUTATE).is_none());
}

#[test]
fn a_new_folder_becomes_a_project_and_opens_its_draft_once_its_row_arrives() {
    let (hub, _dir) = hub();
    let (_keep, path) = folder();
    hub.dispatch("project.folder.open", json!({"path": path}));
    let index = hub.mc.pending(MUTATE).expect("the project is created");
    let call = hub.mc.calls.borrow()[index].clone();
    assert_eq!(call.0, "env-1");
    assert_eq!(call.2["type"], "project.create");
    assert_eq!(call.2["workspaceRoot"], path);
    let id = call.2["projectId"].as_str().unwrap().to_owned();
    hub.mc.reply(&hub.engine, index, Ok(json!({})));
    // The answer came before the row: no draft for a row that is not there.
    assert_ne!(hub.published("route")["kind"], "draft");
    shell(&hub, &[(&id, &path)]);
    assert_eq!(hub.published("route")["kind"], "draft");
}

#[test]
fn a_folder_already_a_project_opens_it_and_a_launch_folder_always_starts_a_thread() {
    let (hub, _dir) = hub();
    let (_keep, path) = folder();
    shell_with(&hub, &[("p1", &path)], &[("t1", "p1")]);
    hub.dispatch("project.folder.open", json!({"path": path}));
    assert!(hub.mc.pending(MUTATE).is_none());
    assert_eq!(hub.published("route")["kind"], "thread");
    hub.dispatch("project.launch", json!({"path": path}));
    assert_eq!(hub.published("route")["kind"], "draft");
}

#[test]
fn a_refused_project_says_so_and_a_disconnected_environment_is_not_asked() {
    let (hub, _dir) = hub();
    let (_keep, path) = folder();
    hub.dispatch("project.folder.open", json!({"path": path}));
    hub.mc
        .answer(&hub.engine, MUTATE, Err(McError::new("read-only")));
    assert_eq!(titles(&hub), ["Could not open folder"]);

    let (hub, _dir) = self::hub();
    hub.mc.set_ready(&hub.engine, false);
    hub.dispatch("project.folder.open", json!({"path": path}));
    assert!(hub.mc.pending(MUTATE).is_none());
    assert_eq!(titles(&hub), ["Could not open folder"]);
}

#[test]
fn a_folder_is_not_opened_where_the_mc_is_elsewhere() {
    let dir = tempfile::tempdir().unwrap();
    let hub = Hub::with(Launch {
        mc_origin: Some("http://build-box:1".into()),
        cache_dir: Some(dir.path().to_owned()),
        ..Launch::default()
    });
    Bridge::of(&hub.engine).set_local_folder_import_enabled(&hub.engine, true);
    hub.mc.set_ready(&hub.engine, true);
    shell(&hub, &[]);
    let (_keep, path) = folder();
    hub.dispatch("project.folder.open", json!({"path": path}));
    assert!(hub.mc.pending(MUTATE).is_none());
    assert!(titles(&hub).is_empty());
}

/// Unpins this machine's id when the test ends, also on a failure.
struct Pinned;

impl Drop for Pinned {
    fn drop(&mut self) {
        this_machine::set_id_for_testing(None);
    }
}

/// env-1 described as running on `machine`.
fn on_machine(hub: &Hub, machine: &str) {
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell", "mcs": [{"mc": "a", "online": true, "epoch": "e", "rev": 1,
            "environment": {"environmentId": "env-1", "label": "Laptop",
                "platform": {"machineId": machine}}}],
            "rows": []}),
    );
}

// Whether the MC runs here is this_machine's answer, not its origin's: an SSH
// port forward is loopback too (tst_ShellRuntime, tst_ThisMachine).
#[test]
fn local_folders_are_the_mcs_only_when_it_runs_on_this_machine() {
    const HERE: &str = "5e1f00000000000000000000000000000000000000000000000000000000c0de";
    let _pinned = Pinned;
    this_machine::set_id_for_testing(Some(HERE.into()));
    let (hub, _dir) = hub();
    let (_keep, path) = folder();
    // Unsaid, the MC on loopback is here.
    assert_eq!(hub.published("sidebar")["localFolders"], true);

    on_machine(&hub, &"a1".repeat(32));
    assert_eq!(hub.published("sidebar")["localFolders"], false);
    hub.dispatch("project.folder.open", json!({"path": path}));
    assert!(hub.mc.pending(MUTATE).is_none());

    on_machine(&hub, HERE);
    assert_eq!(hub.published("sidebar")["localFolders"], true);
    hub.dispatch("project.folder.open", json!({"path": path}));
    assert!(hub.mc.pending(MUTATE).is_some());
}

#[test]
fn add_project_offers_the_one_online_environments_sources() {
    let (hub, _dir) = hub();
    let commands = Commands::of(&hub.engine);
    assert!(commands.is_menu(ADD));
    let choices = commands.choices(&hub.engine, ADD);
    let ids: Vec<_> = choices.iter().map(|c| c.id.as_str()).collect();
    assert_eq!(ids[0], "local-folder");
    assert!(ids.contains(&"clone-url"), "{ids:?}");
    assert_eq!(projects::browse_start(&hub.engine, "env-1"), "~/");
}

#[test]
fn add_project_with_several_environments_asks_which_first() {
    let (hub, _dir) = hub();
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell", "mcs": [
            {"mc": "a", "online": true, "epoch": "e", "rev": 1,
                "environment": {"environmentId": "env-1", "label": "Laptop"}},
            {"mc": "b", "online": false, "epoch": "e", "rev": 1,
                "environment": {"environmentId": "env-2", "label": "Build box"}}],
            "rows": []}),
    );
    // One online: straight to its sources.
    let ids: Vec<_> = Commands::of(&hub.engine)
        .choices(&hub.engine, ADD)
        .into_iter()
        .map(|c| c.id)
        .collect();
    assert_eq!(ids[0], "local-folder");
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell", "mcs": [
            {"mc": "a", "online": true, "epoch": "e", "rev": 2,
                "environment": {"environmentId": "env-1", "label": "Laptop"}},
            {"mc": "b", "online": true, "epoch": "e", "rev": 1,
                "environment": {"environmentId": "env-2", "label": "Build box"}}],
            "rows": []}),
    );
    let choices = Commands::of(&hub.engine).choices(&hub.engine, ADD);
    let shown: Vec<_> = choices
        .iter()
        .map(|c| (c.title.as_str(), c.enabled))
        .collect();
    assert_eq!(shown, [("Laptop", true), ("Build box", true)]);
    assert_eq!(choices[0].description, "This device");
    assert!(choices.iter().all(|c| c.submenu.is_some()));
}

#[test]
fn removal_asks_first_and_deletes_with_the_threads_once_confirmed() {
    let (hub, _dir) = hub();
    shell_with(
        &hub,
        &[("p1", "/w/p1"), ("p2", "/w/p2")],
        &[("t1", "p1"), ("t2", "p1"), ("t3", "p2")],
    );
    hub.dispatch("project.remove", json!({"projectKey": "env-1:p1"}));
    let asked = hub.published("projectRemoval");
    assert_eq!(asked["title"], "p1");
    assert_eq!(asked["kind"], "project");
    assert_eq!(asked["count"], 1);
    assert_eq!(asked["threadCount"], 2);
    assert_eq!(asked["workspaceRoot"], "/w/p1");
    assert_eq!(asked["environment"], "Laptop");
    assert!(hub.mc.pending(MUTATE).is_none());

    hub.dispatch("project.remove.cancel", json!({}));
    assert_eq!(hub.published("projectRemoval"), Json::Null);
    assert!(hub.mc.pending(MUTATE).is_none());

    hub.dispatch("project.remove", json!({"projectKey": "env-1:p1"}));
    hub.dispatch("project.remove.confirm", json!({}));
    assert_eq!(hub.published("projectRemoval"), Json::Null);
    let index = hub.mc.pending(MUTATE).expect("the delete is sent");
    assert_eq!(
        hub.mc.calls.borrow()[index].2,
        json!({"type": "project.delete", "projectId": "p1", "force": true})
    );
    hub.mc.reply(&hub.engine, index, Err(McError::new("busy")));
    assert_eq!(titles(&hub), ["Failed to remove project"]);

    // Nothing asked, nothing to confirm; an unknown project asks nothing.
    hub.dispatch("project.remove.confirm", json!({}));
    hub.dispatch("project.remove", json!({"projectKey": "env-1:gone"}));
    assert_eq!(hub.published("projectRemoval"), Json::Null);
}

#[test]
fn a_question_about_a_project_that_goes_away_meanwhile_is_withdrawn() {
    let (hub, _dir) = hub();
    shell(&hub, &[("p1", "/w/p1")]);
    hub.dispatch("project.remove", json!({"projectKey": "env-1:p1"}));
    assert_ne!(hub.published("projectRemoval"), Json::Null);
    shell(&hub, &[]);
    assert_eq!(hub.published("projectRemoval"), Json::Null);
}

#[test]
fn a_removal_from_the_folder_explorer_is_confirmed_in_settings_on_that_project() {
    let (hub, _dir) = hub();
    shell(&hub, &[("p1", "/w/p1")]);
    hub.dispatch(
        "project.remove",
        json!({"projectKey": "env-1:p1", "inSettings": true}),
    );
    assert_eq!(hub.published("route")["section"], "/settings/projects");
    assert_eq!(hub.published("projectSettings")["status"], "ready");
    assert_ne!(hub.published("projectRemoval"), Json::Null);
}

#[derive(Clone, Debug)]
enum Op {
    Ask(usize),
    Cancel,
    Confirm,
    Vanish(usize),
    Return(usize),
    AnswerDelete(bool),
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        4 => (0usize..2).prop_map(Op::Ask),
        2 => Just(Op::Cancel),
        3 => Just(Op::Confirm),
        2 => (0usize..2).prop_map(Op::Vanish),
        2 => (0usize..2).prop_map(Op::Return),
        2 => any::<bool>().prop_map(Op::AnswerDelete),
    ]
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 128, ..ProptestConfig::default() })]

    /// The question stands for the project asked about until it is answered,
    /// withdrawn or the project goes; only a confirmed one is deleted, once.
    #[test]
    fn a_removal_is_asked_once_and_only_a_confirmed_one_is_sent(
        ops in proptest::collection::vec(op(), 1..40),
    ) {
        let (hub, _dir) = self::hub();
        let ids = ["p0", "p1"];
        let mut present = [true, true];
        let mut asked: Option<usize> = None;
        let mut deletes: Vec<usize> = Vec::new();
        let mut unanswered = 0usize;
        let rows = |present: &[bool; 2]| -> Vec<(&str, String)> {
            ids.iter()
                .zip(present)
                .filter(|(_, here)| **here)
                .map(|(id, _)| (*id, format!("/w/{id}")))
                .collect()
        };
        let send = |present: &[bool; 2]| {
            let rows = rows(present);
            let rows: Vec<(&str, &str)> = rows.iter().map(|(i, r)| (*i, r.as_str())).collect();
            shell(&hub, &rows);
        };
        send(&present);
        for op in ops {
            match op {
                Op::Ask(i) => {
                    hub.dispatch("project.remove", json!({"projectKey": format!("env-1:{}", ids[i])}));
                    if present[i] {
                        asked = Some(i);
                    }
                }
                Op::Cancel => {
                    hub.dispatch("project.remove.cancel", json!({}));
                    asked = None;
                }
                Op::Confirm => {
                    hub.dispatch("project.remove.confirm", json!({}));
                    if let Some(i) = asked.take() {
                        deletes.push(i);
                        unanswered += 1;
                    }
                }
                Op::Vanish(i) => {
                    present[i] = false;
                    send(&present);
                    if asked == Some(i) {
                        asked = None;
                    }
                }
                Op::Return(i) => {
                    present[i] = true;
                    send(&present);
                }
                Op::AnswerDelete(ok) => {
                    if unanswered == 0 {
                        continue;
                    }
                    let index = hub.mc.pending(MUTATE).expect("a delete is waiting");
                    let result = if ok { Ok(json!({})) } else { Err(McError::new("busy")) };
                    hub.mc.reply(&hub.engine, index, result);
                    unanswered -= 1;
                }
            }
            let shown = hub.published("projectRemoval");
            match asked {
                Some(i) => prop_assert_eq!(&shown["projectKey"], &json!(format!("env-1:{}", ids[i]))),
                None => prop_assert_eq!(shown, Json::Null),
            }
            let sent: Vec<String> = hub
                .mc
                .calls
                .borrow()
                .iter()
                .filter(|(_, m, p)| m == MUTATE && p["type"] == "project.delete")
                .map(|(_, _, p)| p["projectId"].as_str().unwrap().to_owned())
                .collect();
            let expected: Vec<String> = deletes.iter().map(|i| ids[*i].to_owned()).collect();
            prop_assert_eq!(sent, expected);
        }
    }
}
