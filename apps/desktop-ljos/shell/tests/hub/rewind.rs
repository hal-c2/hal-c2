//! `rewind`: editing from one of the user's messages, which rolls the
//! thread back to before it and returns its prompt to the composer
//! (RewindController.cpp, CheckpointEditSteps.cpp,
//! features/timeline/checkpoints.feature).

use std::cell::RefCell;
use std::rc::Rc;

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controllers::composer;
use hal_c2_shell::json::{self, Json};
use ljos::prelude::Value;
use serde_json::json;

use crate::Hub;
use crate::page::{failure, toasts};

type Log = Rc<RefCell<Vec<(String, Json)>>>;

/// Thread `t1` of three finished turns, each a prompt, an answer and the
/// checkpoint it left; `t2` beside it. The run of the last turn is
/// `last_run`.
fn three_turns(last_run: &str) -> (Hub, Log) {
    three_turns_with(last_run, json!([]))
}

/// As [`three_turns`], the second prompt carrying `attachments`.
fn three_turns_with(last_run: &str, attachments: Json) -> (Hub, Log) {
    let hub = Hub::clustered();
    hub.mc.set_ready(&hub.engine, true);
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell", "mcs": [{"mc": "a", "online": true, "epoch": "e", "rev": 1,
        "environment": {"environmentId": "env-1", "label": "Here"}}],
        "rows": [
            ["a", "p1", "project", {"id": "p1", "title": "P", "workspaceRoot": "/work/p"}],
            ["a", "t1", "thread", {"id": "t1", "projectId": "p1", "title": "T1",
                "modelSelection": {"instanceId": "opencode", "model": "big-pickle"}}],
            ["a", "t2", "thread", {"id": "t2", "projectId": "p1", "title": "T2"}],
        ]}),
    );
    let bricks = bricks(&hub);
    hub.dispatch("thread.open", json!({"key": "env-1:t1"}));
    let (id, _) = hub
        .mc
        .subscriptions()
        .into_iter()
        .find(|(_, shape)| shape["type"] == "stream" && shape["stream"] == "t1")
        .expect("the thread is followed");
    let mut rows = Vec::new();
    for turn in 1..=3 {
        let run = format!("run-{turn}");
        let status = if turn == 3 { last_run } else { "completed" };
        let prompt = if turn == 2 {
            "check the tax rate".to_owned()
        } else {
            format!("Prompt {turn}")
        };
        rows.push(
            json!(["run", run, {"id": run, "ordinal": turn, "status": status,
            "startedAt": "2026-09-21T14:00:00Z"}]),
        );
        rows.push(
            json!(["turn-item", format!("ask-{turn}"), {"id": format!("ask-{turn}"),
            "type": "user_message", "runId": run, "ordinal": turn * 10, "status": "completed",
            "text": prompt, "attachments": if turn == 2 { attachments.clone() } else { json!([]) }}]),
        );
        rows.push(
            json!(["turn-item", format!("reply-{turn}"), {"id": format!("reply-{turn}"),
            "type": "assistant_message", "runId": run, "ordinal": turn * 10 + 1,
            "status": "completed", "text": format!("Answer {turn}")}]),
        );
        rows.push(
            json!(["checkpoint", format!("cp-{turn}"), {"id": format!("cp-{turn}"),
            "runId": run, "appRunOrdinal": turn, "status": "ready",
            "scopeId": format!("scope-{turn}"), "files": []}]),
        );
    }
    let offset = rows.len();
    hub.mc.frame_to(
        &hub.engine,
        id,
        json!({"t": "snapshot", "part": 0, "rows": rows, "done": true, "offset": offset,
            "handle": "log-1"}),
    );
    hub.mc.frame_to(
        &hub.engine,
        id,
        json!({"t": "live", "offset": offset, "handle": "log-1"}),
    );
    (hub, bricks)
}

/// What the shell asks of the bricks (the composer's actions among them).
fn bricks(hub: &Hub) -> Log {
    let log = Log::default();
    let seen = log.clone();
    hub.engine
        .connect_by_name(
            Bridge::of(&hub.engine).object(),
            "actionRequested",
            move |engine, args| {
                let action = match &args[0] {
                    Value::String(a) => a.to_string(),
                    other => format!("{other:?}"),
                };
                let payload = json::from_value(engine, &args[1]);
                seen.borrow_mut().push((action, payload));
            },
        )
        .unwrap();
    log
}

fn composer(log: &Log) -> Vec<(String, Json)> {
    log.borrow()
        .iter()
        .filter(|(action, _)| action.starts_with("composer."))
        .cloned()
        .collect()
}

/// `t1`'s draft, as the composer keeps it.
fn draft(hub: &Hub) -> String {
    composer::draft(&hub.engine, "env-1:t1")
}

fn rollbacks(hub: &Hub) -> Vec<usize> {
    hub.mc
        .calls
        .borrow()
        .iter()
        .enumerate()
        .filter(|(_, (_, m, p))| {
            m == "orchestration.dispatchCommand" && p["type"] == "checkpoint.rollback"
        })
        .map(|(i, _)| i)
        .collect()
}

fn refusals(hub: &Hub) -> Vec<String> {
    toasts(hub)
        .into_iter()
        .map(|(title, description)| {
            assert_eq!(title, "Could not rewind");
            description
        })
        .collect()
}

#[test]
fn editing_from_a_message_asks_then_rewinds_and_returns_its_prompt() {
    let (hub, bricks) = three_turns("completed");
    hub.dispatch("rewind.request", json!({"rowId": "ask-2"}));
    assert_eq!(
        hub.published("rewind"),
        json!({"threadKey": "env-1:t1", "rowId": "ask-2", "turn": 2})
    );
    assert!(
        rollbacks(&hub).is_empty(),
        "rewound before the user answered"
    );

    hub.dispatch("rewind.confirm", json!({"restoreFiles": true}));
    assert_eq!(hub.published("rewind"), Json::Null);
    let sent = rollbacks(&hub);
    assert_eq!(sent.len(), 1);
    let (environment, _, command) = hub.mc.calls.borrow()[sent[0]].clone();
    assert_eq!(environment, "env-1");
    assert_eq!(command["threadId"], "t1");
    assert_eq!(command["checkpointId"], "cp-1");
    assert_eq!(command["scopeId"], "scope-1");
    assert_eq!(command["restoreFiles"], true);
    // The prompt returns once the MC has rewound.
    assert_eq!(draft(&hub), "");
    hub.mc.reply(&hub.engine, sent[0], Ok(json!({})));
    assert_eq!(draft(&hub), "check the tax rate");
    assert_eq!(
        composer(&bricks),
        [("composer.focus".to_owned(), Json::Null)]
    );
    assert!(refusals(&hub).is_empty());
}

#[test]
fn the_prompt_follows_what_the_composer_holds() {
    let (hub, _) = three_turns("completed");
    hub.dispatch(
        "composer.text.set",
        json!({"target": "env-1:t1", "text": "and the discounts", "cursor": 17}),
    );
    hub.dispatch("rewind.request", json!({"rowId": "ask-2"}));
    hub.dispatch("rewind.confirm", json!({"restoreFiles": true}));
    hub.mc.reply(&hub.engine, rollbacks(&hub)[0], Ok(json!({})));
    assert_eq!(draft(&hub), "and the discounts\n\ncheck the tax rate");
}

#[test]
fn the_files_stay_when_the_user_keeps_them() {
    let (hub, _) = three_turns("completed");
    hub.dispatch("rewind.request", json!({"rowId": "ask-3"}));
    assert_eq!(hub.published("rewind")["turn"], 3);
    hub.dispatch("rewind.confirm", json!({"restoreFiles": false}));
    let sent = rollbacks(&hub);
    let command = hub.mc.calls.borrow()[sent[0]].2.clone();
    assert_eq!(command["checkpointId"], "cp-2");
    assert_eq!(command["restoreFiles"], false);
}

#[test]
fn cancelling_or_leaving_the_thread_changes_nothing() {
    let (hub, bricks) = three_turns("completed");
    hub.dispatch("rewind.request", json!({"rowId": "ask-2"}));
    hub.dispatch("rewind.cancel", json!({}));
    assert_eq!(hub.published("rewind"), Json::Null);
    hub.dispatch("rewind.confirm", json!({"restoreFiles": true}));

    hub.dispatch("rewind.request", json!({"rowId": "ask-2"}));
    hub.dispatch("thread.open", json!({"key": "env-1:t2"}));
    assert_eq!(hub.published("rewind"), Json::Null);
    hub.dispatch("rewind.confirm", json!({"restoreFiles": true}));

    assert!(rollbacks(&hub).is_empty());
    assert!(composer(&bricks).is_empty());
}

#[test]
fn a_rollback_the_mc_refuses_is_said_and_the_draft_is_untouched() {
    let (hub, bricks) = three_turns("completed");
    hub.dispatch("rewind.request", json!({"rowId": "ask-2"}));
    hub.dispatch("rewind.confirm", json!({"restoreFiles": true}));
    let sent = rollbacks(&hub);
    hub.mc
        .reply(&hub.engine, sent[0], Err(failure("The checkpoint is gone")));
    assert_eq!(refusals(&hub), ["The checkpoint is gone"]);
    assert!(composer(&bricks).is_empty());
    assert_eq!(draft(&hub), "");
}

#[test]
fn a_rewind_that_cannot_happen_says_why() {
    // An answer or a reply is not edited from.
    let (hub, _) = three_turns("running");
    hub.dispatch("rewind.request", json!({"rowId": "reply-2"}));
    assert_eq!(hub.published("rewind"), Json::Null);
    assert!(refusals(&hub).is_empty());

    // A turn still running.
    hub.dispatch("rewind.request", json!({"rowId": "ask-2"}));
    assert_eq!(hub.published("rewind"), Json::Null);
    assert_eq!(
        refusals(&hub),
        ["Interrupt the current turn before reverting checkpoints."]
    );

    // The first message, with no baseline before it.
    let (hub, _) = three_turns("completed");
    hub.dispatch("rewind.request", json!({"rowId": "ask-1"}));
    assert_eq!(
        refusals(&hub),
        ["There is no checkpoint before this message to rewind to."]
    );

    // A provider that cannot forget what came after.
    let (hub, _) = three_turns("completed");
    hub.mc.frame(
        &hub.engine,
        "config",
        "",
        json!({"t": "config", "config": {"settings": {}, "keybindingRules": [],
            "providers": [{"instanceId": "opencode", "driver": "opencode", "status": "ready",
                "models": [], "supportsConversationRollback": false}]}}),
    );
    hub.dispatch("rewind.request", json!({"rowId": "ask-2"}));
    assert_eq!(hub.published("rewind"), Json::Null);
    assert_eq!(
        refusals(&hub),
        [
            "This provider does not support reverting conversation history. Start a new thread instead."
        ]
    );
    assert!(rollbacks(&hub).is_empty());
}

fn calls_to(hub: &Hub, method: &str) -> Vec<(String, Json)> {
    hub.mc
        .calls
        .borrow()
        .iter()
        .filter(|(_, m, p)| m == method && !is_favicon(p))
        .map(|(e, _, p)| (e.clone(), p.clone()))
        .collect()
}

/// Whether an `assets.createUrl` signs a project's favicon, which the sidebar
/// asks for alongside the rewind's attachments.
fn is_favicon(payload: &Json) -> bool {
    payload["resource"]["_tag"] == "project-favicon"
}

/// The oldest unanswered signing of an attachment.
fn signing(hub: &Hub) -> usize {
    hub.mc
        .pending_where("assets.createUrl", |p| !is_favicon(p))
        .expect("asked to sign an attachment")
}

/// Answers the oldest attachment's `assets.createUrl` with a URL for `name`,
/// then that URL's download with `body`.
fn serve(hub: &Hub, name: &str, body: Result<&str, &str>) {
    hub.mc.reply(
        &hub.engine,
        signing(hub),
        Ok(json!({"relativeUrl": format!("/attachments/{name}?sig=1")})),
    );
    hub.mc.answer(
        &hub.engine,
        "http.download",
        body.map(Json::from).map_err(failure),
    );
}

#[test]
fn the_attachments_come_back_from_the_mc_before_the_thread_rewinds() {
    let (hub, _) = three_turns_with(
        "completed",
        json!([
            {"type": "image", "id": "a1", "name": "shot.png", "mimeType": "image/png"},
            {"type": "file", "id": "a2", "name": "notes.txt", "mimeType": "text/plain"},
        ]),
    );
    hub.dispatch("rewind.request", json!({"rowId": "ask-2"}));
    hub.dispatch("rewind.confirm", json!({"restoreFiles": true}));
    // One at a time, and nothing rolls back until all are here.
    let asked = calls_to(&hub, "assets.createUrl");
    assert_eq!(asked.len(), 1);
    assert_eq!(asked[0].0, "env-1");
    assert_eq!(
        asked[0].1,
        json!({"resource": {"_tag": "attachment", "attachmentId": "a1",
            "fileName": "shot.png", "mimeType": "image/png"}})
    );
    serve(&hub, "a1", Ok("png-bytes"));
    assert_eq!(
        calls_to(&hub, "http.download")[0].1["relativeUrl"],
        "/attachments/a1?sig=1"
    );
    assert!(rollbacks(&hub).is_empty());
    serve(&hub, "a2", Ok("remember the milk"));
    assert_eq!(rollbacks(&hub).len(), 1);

    hub.mc.reply(&hub.engine, rollbacks(&hub)[0], Ok(json!({})));
    // The composer holds both: the image by its bytes, the file by the path
    // it was written to, which is one of this machine's now.
    let attached: Vec<(String, String)> = hub.published("composer")["attachments"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| {
            (
                a["name"].as_str().unwrap().to_owned(),
                a["kind"].as_str().unwrap().to_owned(),
            )
        })
        .collect();
    assert_eq!(
        attached,
        [
            ("shot.png".to_owned(), "image".to_owned()),
            ("notes.txt".to_owned(), "file".to_owned())
        ]
    );
    let written = std::env::temp_dir().join("hal-c2-rewind/a2/notes.txt");
    assert_eq!(
        std::fs::read_to_string(written).unwrap(),
        "remember the milk"
    );
    assert!(refusals(&hub).is_empty());
}

#[test]
fn an_attachment_that_cannot_be_read_stops_the_rewind() {
    let attachments =
        json!([{"type": "image", "id": "a1", "name": "shot.png", "mimeType": "image/png"}]);

    let (hub, _) = three_turns_with("completed", attachments.clone());
    hub.dispatch("rewind.request", json!({"rowId": "ask-2"}));
    hub.dispatch("rewind.confirm", json!({"restoreFiles": true}));
    hub.mc.reply(
        &hub.engine,
        signing(&hub),
        Err(failure("No such attachment")),
    );
    assert_eq!(refusals(&hub), ["No such attachment"]);
    assert!(rollbacks(&hub).is_empty());

    // The download fails, and a rewind asked for again is not held up.
    let (hub, _) = three_turns_with("completed", attachments);
    hub.dispatch("rewind.request", json!({"rowId": "ask-2"}));
    hub.dispatch("rewind.confirm", json!({"restoreFiles": true}));
    serve(&hub, "a1", Err("HTTP 404"));
    assert_eq!(refusals(&hub), ["HTTP 404"]);
    assert!(rollbacks(&hub).is_empty());
    hub.dispatch("rewind.request", json!({"rowId": "ask-2"}));
    assert_eq!(hub.published("rewind")["turn"], 2);
}
