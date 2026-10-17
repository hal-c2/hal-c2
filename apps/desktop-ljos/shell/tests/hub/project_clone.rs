//! `projectClones`: a toast per clone the MC reports, and the palette steps
//! that start one (ProjectCloneController.cpp, features/projects/clone.feature).

use hal_c2_shell::Launch;
use hal_c2_shell::controllers::project_clone::{self, Chosen};
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::McError;
use proptest::prelude::*;
use serde_json::json;

use crate::Hub;

const AT: &str = "2026-03-01T00:00:00Z";
const START: &str = "projectClone.start";
const LOOKUP: &str = "sourceControl.lookupRepository";

/// A hub with the cluster's `env-1` online and a place to keep drafts.
fn hub() -> (Hub, tempfile::TempDir) {
    let dir = tempfile::tempdir().expect("a cache directory");
    let hub = Hub::with(Launch {
        mc_origin: Some("http://127.0.0.1:1".into()),
        cache_dir: Some(dir.path().to_owned()),
        ..Launch::default()
    });
    shell(&hub, true, &[]);
    (hub, dir)
}

/// The cluster as the shell frame says it: `env-1` and its projects.
fn shell(hub: &Hub, online: bool, projects: &[&str]) {
    let rows: Vec<Json> = projects
        .iter()
        .map(|id| {
            json!(["a", id, "project", {"id": id, "title": id, "workspaceRoot": format!("/w/{id}"),
                "createdAt": AT, "updatedAt": AT}])
        })
        .collect();
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell", "mcs": [{"mc": "a", "online": online, "epoch": "e", "rev": 1,
            "environment": {"environmentId": "env-1", "label": "Laptop", "platform": {"os": "linux"}}}],
            "rows": rows}),
    );
}

fn report(hub: &Hub, clones: Vec<Json>) {
    hub.mc.frame(
        &hub.engine,
        "projectClones",
        "env-1",
        json!({"t": "projectClones", "clones": clones}),
    );
}

fn clone(project: &str, phase: &str) -> Json {
    json!({"projectId": project, "phase": phase, "destinationPath": format!("/w/{project}"),
        "repository": {"nameWithOwner": format!("o/{project}")}})
}

fn toasts(hub: &Hub) -> Vec<Json> {
    hub.published("toasts")["items"].as_array().unwrap().clone()
}

fn titles(hub: &Hub) -> Vec<String> {
    let mut titles: Vec<String> = toasts(hub)
        .iter()
        .map(|t| t["title"].as_str().unwrap().to_owned())
        .collect();
    titles.sort();
    titles
}

fn press(hub: &Hub, title: &str, label: &str) {
    let toast = toasts(hub)
        .into_iter()
        .find(|t| t["title"] == title)
        .unwrap_or_else(|| panic!("no toast {title}"));
    let action = toast["actions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["label"] == label)
        .unwrap_or_else(|| panic!("no action {label}"));
    hub.dispatch(
        "notification.action",
        json!({"id": toast["id"], "actionId": action["id"]}),
    );
}

fn chosen() -> Chosen {
    Chosen {
        environment_id: "env-1".into(),
        remote_url: "https://github.com/o/app.git".into(),
        directory_name: "app".into(),
    }
}

fn count(hub: &Hub, method: &str) -> usize {
    hub.mc.methods().iter().filter(|m| *m == method).count()
}

#[test]
fn every_online_environment_is_followed_and_a_clone_has_one_toast_changed_in_place() {
    let (hub, _dir) = hub();
    let followed: Vec<Json> = hub.mc.subscriptions().into_iter().map(|(_, s)| s).collect();
    assert!(followed.contains(&json!({"type": "projectClones", "environment": "env-1"})));
    let mut running = clone("p1", "running");
    running["stage"] = "receiving".into();
    running["percent"] = 42.into();
    report(&hub, vec![running.clone()]);
    let items = toasts(&hub);
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["title"], "Cloning o/p1");
    assert_eq!(items[0]["description"], "Receiving objects · 42%");
    let id = items[0]["id"].clone();
    // The same report again changes nothing; progress changes the one toast.
    report(&hub, vec![running.clone()]);
    running["percent"] = 80.into();
    report(&hub, vec![running]);
    let items = toasts(&hub);
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["id"], id);
    assert_eq!(items[0]["description"], "Receiving objects · 80%");
    report(&hub, vec![clone("p1", "done")]);
    let items = toasts(&hub);
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["title"], "Cloned o/p1");
    assert_eq!(items[0]["type"], "success");
}

#[test]
fn a_clone_the_mc_stops_reporting_takes_its_toast_unless_it_finished() {
    let (hub, _dir) = hub();
    report(&hub, vec![clone("p1", "running"), clone("p2", "done")]);
    assert_eq!(titles(&hub), ["Cloned o/p2", "Cloning o/p1"]);
    report(&hub, vec![]);
    assert_eq!(titles(&hub), ["Cloned o/p2"]);
    // A finished clone's toast goes in its own time.
    hub.advance(8000);
    assert!(titles(&hub).is_empty());
}

#[test]
fn cancel_retry_and_remove_ask_the_mc_and_leave_the_toast_to_its_report() {
    let (hub, _dir) = hub();
    report(&hub, vec![clone("p1", "running")]);
    press(&hub, "Cloning o/p1", "Cancel");
    let index = hub.mc.pending("projectClone.cancel").expect("cancel asked");
    assert_eq!(hub.mc.calls.borrow()[index].2, json!({"projectId": "p1"}));
    hub.mc.reply(&hub.engine, index, Ok(json!({})));
    assert_eq!(titles(&hub), ["Cloning o/p1"]);

    let mut cancelled = clone("p1", "cancelled");
    cancelled["error"] = "stopped".into();
    report(&hub, vec![cancelled]);
    assert_eq!(titles(&hub), ["Cancelled cloning o/p1"]);
    let mut failed = clone("p1", "failed");
    failed["error"] = "no space".into();
    report(&hub, vec![failed]);
    let items = toasts(&hub);
    assert_eq!(items[0]["title"], "Failed to clone o/p1");
    assert_eq!(items[0]["description"], "no space");
    press(&hub, "Failed to clone o/p1", "Retry");
    assert!(hub.mc.pending("projectClone.retry").is_some());
    assert_eq!(titles(&hub), ["Failed to clone o/p1"]);
    press(&hub, "Failed to clone o/p1", "Remove project");
    let index = hub.mc.pending("projects.mutate").expect("removal asked");
    assert_eq!(
        hub.mc.calls.borrow()[index].2,
        json!({"type": "project.delete", "projectId": "p1"})
    );
    // A removal the MC refuses says so.
    hub.mc
        .reply(&hub.engine, index, Err(McError::new("project has threads")));
    assert!(titles(&hub).contains(&"Failed to remove project".to_owned()));
}

#[test]
fn starting_a_clone_names_the_project_by_its_folder_and_opens_its_draft_once_the_row_arrives() {
    let (hub, _dir) = hub();
    project_clone::start(&hub.engine, &chosen(), " /w/dev/app/ ");
    let index = hub.mc.pending(START).expect("start asked");
    let call = hub.mc.calls.borrow()[index].clone();
    assert_eq!(call.0, "env-1");
    assert_eq!(call.2["title"], "app");
    assert_eq!(call.2["destinationPath"], "/w/dev/app/");
    assert_eq!(call.2["remoteUrl"], "https://github.com/o/app.git");
    let project_id = call.2["projectId"].as_str().unwrap().to_owned();
    // One start at a time.
    project_clone::start(&hub.engine, &chosen(), "/w/other");
    assert_eq!(count(&hub, START), 1);
    hub.mc.reply(&hub.engine, index, Ok(json!({})));
    assert_eq!(hub.published("route")["kind"], "home");
    shell(&hub, true, &[&project_id]);
    assert_eq!(hub.published("route")["kind"], "draft");
    // Free for the next.
    project_clone::start(&hub.engine, &chosen(), "/w/other");
    assert_eq!(count(&hub, START), 2);
}

#[test]
fn a_start_the_mc_refuses_says_why_and_can_be_tried_again() {
    let (hub, _dir) = hub();
    project_clone::start(&hub.engine, &chosen(), "/w/app");
    hub.mc
        .answer(&hub.engine, START, Err(McError::new("destination exists")));
    let items = toasts(&hub);
    assert_eq!(items[0]["title"], "Clone failed");
    assert_eq!(items[0]["description"], "destination exists");
    project_clone::start(&hub.engine, &chosen(), "/w/app2");
    assert_eq!(count(&hub, START), 2);
}

#[test]
fn destinations_are_checked_before_the_mc_is_asked() {
    let (hub, _dir) = hub();
    project_clone::start(&hub.engine, &chosen(), "  ");
    assert_eq!(count(&hub, START), 0);
    project_clone::start(&hub.engine, &chosen(), r"C:\dev\app");
    assert_eq!(titles(&hub), ["Clone failed"]);
    assert_eq!(
        toasts(&hub)[0]["description"],
        "Windows-style paths are only supported on Windows."
    );
    project_clone::start(&hub.engine, &chosen(), "../app");
    assert_eq!(
        toasts(&hub)[0]["description"],
        "Relative paths require an active project."
    );
    assert_eq!(count(&hub, START), 0);
    // An environment that is not connected is not asked.
    shell(&hub, false, &[]);
    project_clone::start(&hub.engine, &chosen(), "/w/app");
    assert_eq!(toasts(&hub)[0]["title"], "Environment unavailable");
    assert_eq!(toasts(&hub)[0]["description"], "Laptop is not connected.");
    assert_eq!(count(&hub, START), 0);
}

#[test]
fn a_provider_is_looked_up_and_only_the_latest_lookup_is_heard() {
    let (hub, _dir) = hub();
    project_clone::submit_repository(&hub.engine, "env-1", "github", "o/app");
    let call = hub.mc.calls.borrow()[hub.mc.pending(LOOKUP).unwrap()].clone();
    assert_eq!(call.2, json!({"provider": "github", "repository": "o/app"}));
    // Busy: a second lookup waits for the first.
    project_clone::submit_repository(&hub.engine, "env-1", "github", "o/other");
    assert_eq!(count(&hub, LOOKUP), 1);
    hub.mc
        .answer(&hub.engine, LOOKUP, Err(McError::new("not found")));
    assert_eq!(titles(&hub), ["Repository lookup failed"]);
    project_clone::submit_repository(&hub.engine, "env-1", "github", "o/other");
    assert_eq!(count(&hub, LOOKUP), 2);
}

#[test]
fn providers_not_ready_open_source_control_and_ready_ones_come_first() {
    let (hub, _dir) = hub();
    let choices = project_clone::sources(&hub.engine, "env-1");
    assert_eq!(choices[0].title, "Git URL");
    assert!(
        choices[1..]
            .iter()
            .all(|c| c.description.starts_with("Setup Required"))
    );
    hub.mc.answer(
        &hub.engine,
        "server.discoverSourceControl",
        Ok(json!({"sourceControlProviders": [
            {"kind": "gitlab", "label": "GitLab", "status": "available", "auth": {"status": "authenticated"}},
            {"kind": "github", "label": "GitHub", "status": "available",
             "auth": {"status": "unauthenticated", "detail": {"_tag": "Some", "value": "Run gh auth login"}}},
        ]})),
    );
    let choices = project_clone::sources(&hub.engine, "env-1");
    let titles: Vec<&str> = choices.iter().map(|c| c.title.as_str()).collect();
    assert_eq!(
        titles[..3],
        ["Git URL", "GitLab repository", "Azure DevOps repository"]
    );
    let github = choices
        .iter()
        .find(|c| c.title == "GitHub repository")
        .unwrap();
    assert_eq!(github.description, "Setup Required · Run gh auth login");
    // Setup Required goes to the settings.
    (github.run.clone().unwrap())(&hub.engine);
    assert_eq!(
        hub.published("route")["section"],
        "/settings/source-control"
    );
}

/// What the lookups and starts in flight and the busy flag should be.
#[derive(Clone, Debug)]
enum Op {
    /// Choosing the provider again: asks for a repository afresh.
    Ask,
    Submit,
    AnswerLookup(usize, bool),
    Start,
    AnswerStart(usize, bool),
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        2 => Just(Op::Ask),
        4 => Just(Op::Submit),
        4 => (0usize..3, any::<bool>()).prop_map(|(i, ok)| Op::AnswerLookup(i, ok)),
        4 => Just(Op::Start),
        4 => (0usize..3, any::<bool>()).prop_map(|(i, ok)| Op::AnswerStart(i, ok)),
    ]
}

#[derive(Default)]
struct Model {
    busy: bool,
    generation: u32,
    /// Lookups not answered: (call index, generation).
    lookups: Vec<(usize, u32)>,
    starts: Vec<usize>,
    calls: usize,
    errors: usize,
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 128, ..ProptestConfig::default() })]

    /// Replies come in any order: a lookup the user moved past is not heard,
    /// and nothing starts while one is in flight.
    #[test]
    fn lookups_and_starts_follow_their_model(ops in proptest::collection::vec(op(), 1..40)) {
        let (hub, _dir) = hub();
        // A ready GitHub, so choosing it asks for a repository.
        project_clone::sources(&hub.engine, "env-1");
        hub.mc.answer(&hub.engine, "server.discoverSourceControl", Ok(json!({"sourceControlProviders": [
            {"kind": "github", "label": "GitHub", "status": "available", "auth": {"status": "authenticated"}}]})));
        let github = project_clone::sources(&hub.engine, "env-1")
            .into_iter()
            .find(|c| c.id == "clone-github")
            .unwrap();
        let mut model = Model::default();
        for op in ops {
            match op {
                Op::Ask => {
                    (github.run.clone().unwrap())(&hub.engine);
                    model.busy = false;
                    model.generation += 1;
                }
                Op::Submit => {
                    project_clone::submit_repository(&hub.engine, "env-1", "github", "o/app");
                    if !model.busy {
                        model.busy = true;
                        model.generation += 1;
                        model.lookups.push((model.calls, model.generation));
                        model.calls += 1;
                    }
                }
                Op::AnswerLookup(i, ok) => {
                    if model.lookups.is_empty() { continue; }
                    let (index, generation) = model.lookups.remove(i % model.lookups.len());
                    let result = if ok {
                        Ok(json!({"provider": "github", "url": "https://github.com/o/app.git", "nameWithOwner": "o/app"}))
                    } else {
                        Err(McError::new("nope"))
                    };
                    hub.mc.reply(&hub.engine, absolute(&hub, LOOKUP, index), result);
                    if generation == model.generation {
                        model.busy = false;
                        if !ok { model.errors += 1; }
                    }
                }
                Op::Start => {
                    project_clone::start(&hub.engine, &chosen(), "/w/app");
                    if !model.busy {
                        model.busy = true;
                        model.starts.push(model.calls);
                        model.calls += 1;
                    }
                }
                Op::AnswerStart(i, ok) => {
                    if model.starts.is_empty() { continue; }
                    let index = model.starts.remove(i % model.starts.len());
                    let result = if ok { Ok(json!({})) } else { Err(McError::new("nope")) };
                    hub.mc.reply(&hub.engine, absolute(&hub, START, index), result);
                    model.busy = false;
                    if !ok { model.errors += 1; }
                }
            }
            let lookups = count(&hub, LOOKUP);
            let starts = count(&hub, START);
            prop_assert_eq!(lookups + starts, model.calls);
            let failed = toasts(&hub)
                .iter()
                .filter(|t| t["type"] == "error")
                .count();
            prop_assert_eq!(failed, model.errors);
        }
    }
}

/// The index in `calls` of the `n`th call (counting both lookups and starts
/// the model made) to `method`.
fn absolute(hub: &Hub, method: &str, n: usize) -> usize {
    // The model numbers calls to both methods together; the discovery call
    // came first, so find the one at that place among the two.
    let calls = hub.mc.calls.borrow();
    calls
        .iter()
        .enumerate()
        .filter(|(_, (_, m, _))| m == LOOKUP || m == START)
        .nth(n)
        .filter(|(_, (_, m, _))| m == method)
        .map(|(i, _)| i)
        .expect("the call the model made")
}
