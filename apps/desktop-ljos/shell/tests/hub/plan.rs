//! `plan`: implementing a proposed plan in a new thread, and copies of it on
//! the clipboard, in Downloads and in the workspace (PlanController.cpp,
//! PlanSteps.cpp, features/timeline/plans-and-subagents.feature).

use std::cell::RefCell;
use std::rc::Rc;

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controllers::plan::Plan;
use hal_c2_shell::controllers::thread_menu::ThreadMenu;
use hal_c2_shell::json::Json;
use serde_json::json;

use crate::Hub;
use crate::page::{failure, toasts};

const PLAN: &str = "# Tax line\n\n- Add the line\n- Test it\n";

/// Threads `t1` (in the project's checkout) and `t2` (in a worktree) of
/// project `p1`, whose workspace is `root` (none: unavailable); `t1` open,
/// offering the plan.
fn hub(root: Option<&str>) -> Hub {
    let hub = Hub::clustered();
    hub.mc.set_ready(&hub.engine, true);
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell", "mcs": [{"mc": "a", "online": true, "epoch": "e", "rev": 1,
        "environment": {"environmentId": "env-1", "label": "Here"}}],
        "rows": [
            ["a", "p1", "project", {"id": "p1", "title": "P", "workspaceRoot": root}],
            ["a", "t1", "thread", {"id": "t1", "projectId": "p1", "title": "T1",
                "runtimeMode": "approval-required",
                "modelSelection": {"instanceId": "codex", "model": "gpt-5"}}],
            ["a", "t2", "thread", {"id": "t2", "projectId": "p1", "title": "T2",
                "branch": "tax", "worktreePath": "/work/p-tax"}],
        ]}),
    );
    offer(&hub, "t1");
    hub
}

/// Opens `thread`, which offers the plan.
fn offer(hub: &Hub, thread: &str) {
    let key = format!("env-1:{thread}");
    hub.dispatch("thread.open", json!({"key": key}));
    Bridge::of(&hub.engine).publish(
        &hub.engine,
        "turn",
        json!({"threadKey": key, "plan": {"id": "plan-1", "markdown": PLAN}}),
    );
}

fn shown(hub: &Hub) -> String {
    hub.published("route")["threadKey"]
        .as_str()
        .unwrap_or_default()
        .to_owned()
}

/// The calls to `method` so far (dispatched commands by their type), as
/// indexes into the MC's calls.
fn calls(hub: &Hub, method: &str) -> Vec<usize> {
    hub.mc
        .calls
        .borrow()
        .iter()
        .enumerate()
        .filter(|(_, (_, m, p))| {
            m == method || (m == "orchestration.dispatchCommand" && p["type"] == method)
        })
        .map(|(i, _)| i)
        .collect()
}

fn payload(hub: &Hub, index: usize) -> Json {
    hub.mc.calls.borrow()[index].2.clone()
}

#[test]
fn a_new_thread_is_started_then_sent_the_plan_and_the_window_moves_to_it() {
    let hub = hub(Some("/work/p"));
    hub.dispatch("plan.implementInNewThread", json!({}));
    let launched = calls(&hub, "orchestration.launchThread");
    assert_eq!(launched.len(), 1);
    let launch = payload(&hub, launched[0]);
    let thread = launch["threadId"].as_str().unwrap().to_owned();
    assert!(!thread.is_empty() && thread != "t1");
    assert_eq!(launch["projectId"], "p1");
    assert_eq!(launch["title"], "Implement Tax line");
    assert_eq!(launch["interactionMode"], "default");
    assert_eq!(launch["runtimeMode"], "approval-required");
    assert_eq!(launch["workspaceStrategy"], json!({"type": "root"}));
    assert_eq!(
        launch["modelSelection"],
        json!({"instanceId": "codex", "model": "gpt-5"})
    );
    // Asked again while it starts, nothing more is.
    hub.dispatch("plan.implementInNewThread", json!({}));
    assert_eq!(calls(&hub, "orchestration.launchThread").len(), 1);

    // The thread first, then its first message.
    assert!(calls(&hub, "message.dispatch").is_empty());
    hub.mc.reply(&hub.engine, launched[0], Ok(json!({})));
    let sent = calls(&hub, "message.dispatch");
    assert_eq!(sent.len(), 1);
    let message = payload(&hub, sent[0]);
    assert_eq!(message["threadId"], thread.as_str());
    assert_eq!(
        message["text"],
        "PLEASE IMPLEMENT THIS PLAN:\n# Tax line\n\n- Add the line\n- Test it"
    );
    assert_eq!(
        message["sourcePlanRef"],
        json!({"threadId": "t1", "planId": "plan-1"})
    );
    assert_eq!(shown(&hub), "env-1:t1");
    hub.mc.reply(&hub.engine, sent[0], Ok(json!({})));
    assert_eq!(shown(&hub), format!("env-1:{thread}"));
    // The planning thread was sent nothing.
    for (_, _, p) in hub.mc.calls.borrow().iter() {
        assert_ne!(p["threadId"], "t1", "{p}");
    }
}

#[test]
fn a_thread_in_a_worktree_starts_its_implementation_there() {
    let hub = hub(Some("/work/p"));
    offer(&hub, "t2");
    hub.dispatch("plan.implementInNewThread", json!({}));
    let launch = payload(&hub, calls(&hub, "orchestration.launchThread")[0]);
    assert_eq!(
        launch["workspaceStrategy"],
        json!({"type": "existing_worktree", "worktreePath": "/work/p-tax", "branch": "tax"})
    );
    assert_eq!(launch["runtimeMode"], "full-access");
    assert!(launch.get("modelSelection").is_none());
}

#[test]
fn a_thread_that_cannot_start_says_why_and_can_be_asked_again() {
    let hub = hub(Some("/work/p"));
    hub.dispatch("plan.implementInNewThread", json!({}));
    let launched = calls(&hub, "orchestration.launchThread");
    hub.mc.reply(
        &hub.engine,
        launched[0],
        Err(failure("Provider unavailable")),
    );
    assert!(calls(&hub, "message.dispatch").is_empty());
    assert_eq!(
        toasts(&hub),
        [(
            "Could not start implementation thread".to_owned(),
            "Provider unavailable".to_owned()
        )]
    );
    assert_eq!(shown(&hub), "env-1:t1");
    hub.dispatch("plan.implementInNewThread", json!({}));
    assert_eq!(calls(&hub, "orchestration.launchThread").len(), 2);
}

#[test]
fn a_new_thread_its_plan_never_reached_is_deleted() {
    let hub = hub(Some("/work/p"));
    hub.dispatch("plan.implementInNewThread", json!({}));
    let launched = calls(&hub, "orchestration.launchThread");
    let thread = payload(&hub, launched[0])["threadId"].clone();
    hub.mc.reply(&hub.engine, launched[0], Ok(json!({})));
    let sent = calls(&hub, "message.dispatch");
    hub.mc
        .reply(&hub.engine, sent[0], Err(failure("Provider unavailable")));
    let deleted = calls(&hub, "thread.delete");
    assert_eq!(deleted.len(), 1);
    assert_eq!(payload(&hub, deleted[0])["threadId"], thread);
    assert_eq!(toasts(&hub).len(), 1);
    assert_eq!(shown(&hub), "env-1:t1");
}

#[test]
fn the_plan_is_copied_and_downloaded_without_writing_over_an_earlier_one() {
    let hub = hub(Some("/work/p"));
    let copied = Rc::new(RefCell::new(Vec::<String>::new()));
    let into = copied.clone();
    hub.with_controller::<ThreadMenu, _>(|m, _| {
        m.set_clipboard_writer(Rc::new(move |_, text| {
            into.borrow_mut().push(text.to_owned());
            true
        }));
    });
    hub.dispatch("plan.copy", json!({}));
    assert_eq!(*copied.borrow(), [PLAN]);
    assert_eq!(toasts(&hub)[0].0, "Plan copied");

    let dir = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).unwrap();
    let downloads = dir.path().join("downloads");
    let folder = downloads.clone();
    hub.with_controller::<Plan, _>(|p, _| p.set_download_directory(Some(folder)));
    hub.dispatch("plan.download", json!({}));
    let first = downloads.join("tax-line.md");
    assert_eq!(std::fs::read_to_string(&first).unwrap(), PLAN);
    hub.dispatch("plan.download", json!({}));
    assert_eq!(
        std::fs::read_to_string(downloads.join("tax-line (2).md")).unwrap(),
        PLAN
    );
    assert!(
        toasts(&hub).contains(&("Plan downloaded".to_owned(), first.display().to_string())),
        "{:?}",
        toasts(&hub)
    );
}

#[test]
fn the_plan_is_saved_into_the_threads_workspace() {
    let hub = hub(Some("/work/p"));
    hub.dispatch("plan.save", json!({"path": " docs/tax-plan.md "}));
    let written = calls(&hub, "projects.writeFile");
    assert_eq!(
        payload(&hub, written[0]),
        json!({"cwd": "/work/p", "relativePath": "docs/tax-plan.md", "contents": PLAN})
    );
    hub.mc.reply(
        &hub.engine,
        written[0],
        Ok(json!({"relativePath": "docs/tax-plan.md"})),
    );
    assert_eq!(
        toasts(&hub),
        [(
            "Plan saved to workspace".to_owned(),
            "docs/tax-plan.md".to_owned()
        )]
    );

    // Without a path it is named after the plan, in the thread's worktree.
    offer(&hub, "t2");
    hub.dispatch("plan.save", json!({}));
    let written = calls(&hub, "projects.writeFile");
    let second = payload(&hub, written[1]);
    assert_eq!(second["cwd"], "/work/p-tax");
    assert_eq!(second["relativePath"], "tax-line.md");
}

#[test]
fn without_a_workspace_nothing_is_written() {
    let hub = hub(None);
    hub.dispatch("plan.save", json!({"path": "docs/tax-plan.md"}));
    assert!(calls(&hub, "projects.writeFile").is_empty());
    assert_eq!(
        toasts(&hub),
        [(
            "Workspace path is unavailable".to_owned(),
            "This thread does not have a workspace path to save into.".to_owned()
        )]
    );
}

#[test]
fn only_the_open_threads_plan_is_acted_on() {
    let hub = hub(Some("/work/p"));
    // The plan said is another thread's.
    hub.dispatch("thread.open", json!({"key": "env-1:t2"}));
    hub.dispatch("plan.implementInNewThread", json!({}));
    hub.dispatch("plan.save", json!({"path": "x.md"}));
    assert!(calls(&hub, "orchestration.launchThread").is_empty());
    assert!(calls(&hub, "projects.writeFile").is_empty());
}
