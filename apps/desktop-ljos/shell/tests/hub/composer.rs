//! `composer`: the route thread's composer and its sends against the MC
//! (ComposerController.cpp, features/composer/, tst_ComposerRegression.cpp,
//! tst_ComposerProp.cpp).

use hal_c2_shell::controllers::composer;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::McError;
use serde_json::json;

use crate::Hub;
use crate::page::toasts;
use crate::workspace::{AT, clustered, project, shell};

pub const DISPATCH: &str = "orchestration.dispatchCommand";

/// Thread `id` of p1, its agent idle on Codex.
pub fn thread_row(id: &str) -> Json {
    json!(["a", id, "thread", {"id": id, "projectId": "p1", "title": format!("Thread {id}"),
        "branch": "main", "worktreePath": null, "runtimeMode": "full-access",
        "interactionMode": "default",
        "modelSelection": {"instanceId": "codex", "model": "gpt-a"},
        "createdAt": AT, "updatedAt": AT}])
}

/// A hub with the MC up, project p1 and its threads `ids`, showing the
/// first.
pub fn on_threads(ids: &[&str]) -> Hub {
    on_threads_with(hal_c2_shell::Launch::default(), ids)
}

/// A hub keeping its files in a fresh home named `test`.
pub fn launch_in(test: &str) -> hal_c2_shell::Launch {
    let home = crate::workspace::scratch(&format!("composer-{test}"));
    hal_c2_shell::Launch {
        config_dir: Some(home.join("config")),
        data_dir: Some(home.join("data")),
        ..hal_c2_shell::Launch::default()
    }
}

pub fn on_threads_with(launch: hal_c2_shell::Launch, ids: &[&str]) -> Hub {
    let hub = clustered(launch);
    hub.mc.set_ready(&hub.engine, true);
    let mut rows = vec![project(json!({}))];
    rows.extend(ids.iter().map(|id| thread_row(id)));
    shell(&hub, rows);
    open(&hub, ids[0]);
    hub
}

pub fn open(hub: &Hub, id: &str) {
    hub.dispatch("thread.open", json!({"key": format!("env-1:{id}")}));
}

/// Types `text` into the shown composer and sends it.
pub fn send(hub: &Hub, text: &str) {
    let target = hub.published("composer")["target"]
        .as_str()
        .unwrap_or_default()
        .to_owned();
    hub.dispatch(
        "composer.text.set",
        json!({"target": target, "text": text, "cursor": text.encode_utf16().count()}),
    );
    hub.dispatch("composer.submit", json!({}));
}

/// The dispatched commands (`type`, `threadId`, `text`), oldest first.
pub fn commands(hub: &Hub) -> Vec<Json> {
    hub.mc
        .calls
        .borrow()
        .iter()
        .filter(|(_, method, _)| method == DISPATCH)
        .map(|(_, _, command)| command.clone())
        .collect()
}

/// The index of the oldest unanswered dispatch to thread `id`.
pub fn pending_to(hub: &Hub, id: &str) -> Option<usize> {
    let calls = hub.mc.calls.borrow();
    (0..calls.len())
        .find(|&i| calls[i].1 == DISPATCH && calls[i].2["threadId"] == id && hub.mc.is_pending(i))
}

/// The label of toast `index`'s first action.
pub fn action_of(hub: &Hub, index: usize) -> String {
    hub.published("toasts")["items"][index]["actions"][0]["label"]
        .as_str()
        .unwrap_or_default()
        .to_owned()
}

pub fn draft(hub: &Hub, id: &str) -> String {
    composer::draft(&hub.engine, &format!("env-1:{id}"))
}

#[test]
fn a_send_dispatches_its_message_and_empties_the_draft() {
    let hub = on_threads(&["t1"]);
    assert_eq!(hub.published("composer")["target"], "env-1:t1");
    send(&hub, "  hello  ");
    let sent = commands(&hub);
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0]["type"], "message.dispatch");
    assert_eq!(sent[0]["text"], "hello");
    assert_eq!(sent[0]["titleSeed"], "hello");
    assert_eq!(sent[0]["dispatchMode"]["type"], "start_immediately");
    assert_eq!(sent[0]["deliveryIntent"], "auto");
    assert_eq!(draft(&hub, "t1"), "");
    hub.mc.answer(&hub.engine, DISPATCH, Ok(json!({})));
    assert!(toasts(&hub).is_empty());
}

#[test]
fn a_blank_prompt_sends_nothing() {
    let hub = on_threads(&["t1"]);
    send(&hub, "   ");
    assert!(commands(&hub).is_empty());
}

#[test]
fn a_thread_sends_one_message_at_a_time_in_order() {
    let hub = on_threads(&["t1"]);
    send(&hub, "first");
    send(&hub, "second");
    // The second waits for the MC to take the first.
    assert_eq!(commands(&hub).len(), 1);
    hub.mc.answer(&hub.engine, DISPATCH, Ok(json!({})));
    let sent = commands(&hub);
    assert_eq!(sent.len(), 2);
    assert_eq!(sent[1]["text"], "second");
}

#[test]
fn a_refused_send_comes_back_to_an_empty_draft_with_the_ones_behind_it() {
    let hub = on_threads(&["t1"]);
    send(&hub, "first");
    send(&hub, "second");
    hub.mc
        .answer(&hub.engine, DISPATCH, Err(McError::new("thread is busy")));
    assert_eq!(draft(&hub, "t1"), "first\n\nsecond");
    assert_eq!(commands(&hub).len(), 1);
    assert_eq!(toasts(&hub)[0].0, "Failed to send message");
}

#[test]
fn a_refused_prompt_behind_newer_typing_waits_behind_the_toast() {
    let hub = on_threads(&["t1"]);
    send(&hub, "first");
    hub.dispatch(
        "composer.text.set",
        json!({"target": "env-1:t1", "text": "newer", "cursor": 5}),
    );
    hub.mc
        .answer(&hub.engine, DISPATCH, Err(McError::new("thread is busy")));
    // The newer typing stays.
    assert_eq!(draft(&hub, "t1"), "newer");
    assert_eq!(toasts(&hub)[0].0, "Failed to send message");
    assert_eq!(action_of(&hub, 0), "Restore prompt");
}

#[test]
fn sends_to_two_threads_are_answered_in_any_order() {
    let hub = on_threads(&["t1", "t2"]);
    send(&hub, "to one");
    open(&hub, "t2");
    send(&hub, "to two");
    let two = pending_to(&hub, "t2").expect("t2's send");
    hub.mc.reply(&hub.engine, two, Ok(json!({})));
    let one = pending_to(&hub, "t1").expect("t1's send");
    hub.mc.reply(&hub.engine, one, Err(McError::new("refused")));
    assert_eq!(draft(&hub, "t1"), "to one");
    assert_eq!(draft(&hub, "t2"), "");
}

#[test]
fn nothing_leaves_while_the_mc_is_out_of_reach() {
    let hub = on_threads(&["t1"]);
    hub.mc.set_ready(&hub.engine, false);
    send(&hub, "hello");
    assert!(commands(&hub).is_empty());
    assert_eq!(draft(&hub, "t1"), "hello");
    assert_eq!(toasts(&hub)[0].0, "Not connected: message not sent");
}

#[test]
fn a_dropped_answer_keeps_the_send_for_the_thread_to_settle() {
    let hub = on_threads(&["t1"]);
    send(&hub, "hello");
    hub.mc
        .answer(&hub.engine, DISPATCH, Err(McError::new("disconnected")));
    // Neither restored nor toasted: the thread's messages will tell.
    assert_eq!(draft(&hub, "t1"), "");
    assert!(toasts(&hub).is_empty());
}

/// Clicks toast `index`'s first action.
pub fn click(hub: &Hub, index: usize) {
    let id = hub.published("toasts")["items"][index]["id"].clone();
    hub.dispatch(
        "notification.action",
        json!({"id": id, "actionId": "primary"}),
    );
}

#[test]
fn restore_prompt_waits_for_an_empty_draft() {
    let hub = on_threads(&["t1"]);
    send(&hub, "first");
    hub.dispatch(
        "composer.text.set",
        json!({"target": "env-1:t1", "text": "newer", "cursor": 5}),
    );
    hub.mc
        .answer(&hub.engine, DISPATCH, Err(McError::new("thread is busy")));
    // Not over the newer typing.
    click(&hub, 0);
    assert_eq!(draft(&hub, "t1"), "newer");
}

#[test]
fn restore_prompt_gives_the_refused_prompt_back_to_an_emptied_draft() {
    let hub = on_threads(&["t1"]);
    send(&hub, "first");
    hub.dispatch(
        "composer.text.set",
        json!({"target": "env-1:t1", "text": "newer", "cursor": 5}),
    );
    hub.mc
        .answer(&hub.engine, DISPATCH, Err(McError::new("thread is busy")));
    hub.dispatch(
        "composer.text.set",
        json!({"target": "env-1:t1", "text": "", "cursor": 0}),
    );
    click(&hub, 0);
    assert_eq!(draft(&hub, "t1"), "first");
}

/// The environment's providers: Codex (gpt-a, gpt-b) and Claude
/// (claude-a), both with plan mode.
pub fn providers(hub: &Hub) {
    let model =
        |slug: &str, default: bool| json!({"slug": slug, "name": slug, "isDefault": default});
    hub.mc.frame(
        &hub.engine,
        "config",
        "",
        json!({"t": "config", "config": {"availableEditors": [], "keybindingRules": [],
            "providers": [
                {"instanceId": "codex", "driver": "codex", "enabled": true, "status": "ready",
                 "models": [model("gpt-a", true), model("gpt-b", false)]},
                {"instanceId": "claudeAgent", "driver": "claudeAgent", "enabled": true,
                 "status": "ready", "models": [model("claude-a", true)]}]}}),
    );
}

#[test]
fn another_providers_model_moves_the_thread_to_it_before_the_message() {
    let hub = on_threads(&["t1"]);
    providers(&hub);
    hub.dispatch(
        "composer.model.select",
        json!({"instanceId": "claudeAgent", "model": "claude-a"}),
    );
    send(&hub, "over to you");
    let switch = &commands(&hub)[0];
    assert_eq!(switch["type"], "provider.switch");
    assert_eq!(switch["modelSelection"]["instanceId"], "claudeAgent");
    hub.mc.answer(&hub.engine, DISPATCH, Ok(json!({})));
    let message = &commands(&hub)[1];
    assert_eq!(message["type"], "message.dispatch");
    assert_eq!(message["modelSelection"]["model"], "claude-a");
}

/// A hub showing a new thread's draft in p1.
fn on_draft() -> (Hub, String) {
    let hub = on_threads(&["t1"]);
    hub.dispatch("thread.new", json!(null));
    let target = hub.published("composer")["target"]
        .as_str()
        .unwrap_or_default()
        .to_owned();
    assert!(
        !target.is_empty() && !target.contains(':'),
        "a draft: {target}"
    );
    (hub, target)
}

const LAUNCH: &str = "orchestration.launchThread";

#[test]
fn a_drafts_first_send_launches_its_thread_and_the_draft_becomes_it() {
    let (hub, id) = on_draft();
    send(&hub, "build the thing");
    let launch = crate::page::last(&hub, "env-1", LAUNCH);
    assert_eq!(launch["projectId"], "p1");
    assert_eq!(launch["title"], "build the thing");
    assert_eq!(launch["initialMessage"]["text"], "build the thing");
    assert_eq!(launch["workspaceStrategy"]["type"], "root");
    // Sending: the composer holds nothing while the MC answers.
    assert_eq!(composer::draft(&hub.engine, &id), "");
    let thread_id = launch["threadId"].as_str().unwrap().to_owned();
    hub.mc
        .answer(&hub.engine, LAUNCH, Ok(json!({"threadId": thread_id})));
    assert!(toasts(&hub).is_empty());
    assert!(hal_c2_shell::controllers::drafts::draft(&hub.engine, &id).is_none());
}

#[test]
fn a_refused_launch_gives_the_draft_its_prompt_back() {
    let (hub, id) = on_draft();
    send(&hub, "build the thing");
    hub.mc
        .answer(&hub.engine, LAUNCH, Err(McError::new("no provider")));
    assert_eq!(composer::draft(&hub.engine, &id), "build the thing");
    assert_eq!(
        toasts(&hub)[0],
        ("Could not create thread".into(), "no provider".into())
    );
}

#[test]
fn a_background_send_leaves_the_draft_for_the_next_prompt() {
    let (hub, id) = on_draft();
    hub.dispatch(
        "composer.text.set",
        json!({"target": id, "text": "in the back", "cursor": 11}),
    );
    hub.dispatch("composer.submit", json!({"intent": "background"}));
    assert_eq!(hub.published("composer")["target"], id.as_str());
    let launch = crate::page::last(&hub, "env-1", LAUNCH);
    hub.mc.answer(
        &hub.engine,
        LAUNCH,
        Ok(json!({"threadId": launch["threadId"]})),
    );
    assert_eq!(toasts(&hub)[0].0, "Started 1 thread in background");
    assert_eq!(action_of(&hub, 0), "Open");
    assert!(hal_c2_shell::controllers::drafts::draft(&hub.engine, &id).is_some());
}

#[test]
fn stop_interrupts_the_running_turn() {
    let hub = on_threads(&["t1"]);
    let mut row = thread_row("t1");
    row[3]["activeRunId"] = json!("r1");
    shell(&hub, vec![project(json!({})), row]);
    hub.dispatch("composer.interrupt", json!({}));
    let stop = crate::page::last(&hub, "env-1", DISPATCH);
    assert_eq!(stop["type"], "run.interrupt");
    assert_eq!(stop["runId"], "r1");
}

#[test]
fn a_send_during_a_turn_steers_and_the_alternate_queues() {
    let hub = on_threads(&["t1"]);
    let mut row = thread_row("t1");
    row[3]["activeRunId"] = json!("r1");
    shell(&hub, vec![project(json!({})), row]);
    send(&hub, "steer");
    hub.mc.answer(&hub.engine, DISPATCH, Ok(json!({})));
    hub.dispatch(
        "composer.text.set",
        json!({"target": "env-1:t1", "text": "later", "cursor": 5}),
    );
    hub.dispatch("composer.submit", json!({"intent": "alternate"}));
    let sent = commands(&hub);
    assert_eq!(sent[0]["deliveryIntent"], "steer");
    assert_eq!(sent[1]["dispatchMode"]["type"], "queue_after_active");
}

#[test]
fn slash_plan_switches_the_mode_without_sending() {
    let hub = on_threads_with(launch_in("slash-plan"), &["t1"]);
    providers(&hub);
    hal_c2_shell::controllers::settings::Settings::of(&hub.engine).write_device(
        &hub.engine,
        "planModeEnabled",
        json!(true),
    );
    send(&hub, "/plan");
    assert!(commands(&hub).is_empty());
    assert_eq!(draft(&hub, "t1"), "");
    send(&hub, "think first");
    let sent = commands(&hub);
    assert_eq!(sent[0]["type"], "thread.interaction-mode.set");
    assert_eq!(sent[0]["interactionMode"], "plan");
    hub.mc.answer(&hub.engine, DISPATCH, Ok(json!({})));
    assert_eq!(commands(&hub)[1]["text"], "think first");
}

#[test]
fn the_stash_keeps_a_draft_and_gives_it_back() {
    let hub = on_threads(&["t1"]);
    hub.dispatch(
        "composer.text.set",
        json!({"target": "env-1:t1", "text": "for later", "cursor": 9}),
    );
    hub.dispatch("composer.stash", json!({}));
    assert_eq!(draft(&hub, "t1"), "");
    let entries = hub.published("composerStash")["entries"].clone();
    assert_eq!(entries[0]["snippet"], "for later");
    hub.dispatch("composer.stash.restore", json!({"id": entries[0]["id"]}));
    assert_eq!(draft(&hub, "t1"), "for later");
    assert_eq!(hub.published("composerStash")["entries"], json!([]));
}

#[test]
fn the_composer_reads_the_open_threads_timeline() {
    let hub = on_threads(&["t1"]);
    assert_eq!(hub.published("turn")["approvals"], json!([]));
    let (id, _) = hub
        .mc
        .subscriptions()
        .into_iter()
        .find(|(_, shape)| shape["type"] == "stream" && shape["stream"] == "t1")
        .expect("the thread is followed");
    hub.mc.frame_to(
        &hub.engine,
        id,
        json!({"t": "snapshot", "part": 0, "done": true, "offset": 0, "handle": "log-1", "rows": [
            ["runtime-request", "request-1", {"id": "request-1", "status": "pending"}],
            ["turn-item", "ask-1", {"id": "ask-1", "type": "approval_request", "ordinal": 1,
                "requestId": "request-1", "requestKind": "command", "prompt": "Run rm -rf dist?"}],
        ]}),
    );
    hub.mc.frame_to(
        &hub.engine,
        id,
        json!({"t": "live", "offset": 0, "handle": "log-1"}),
    );
    let approvals = hub.published("turn")["approvals"].clone();
    assert_eq!(approvals[0]["requestId"], "request-1");
    assert_eq!(approvals[0]["detail"], "Run rm -rf dist?");
}

#[test]
fn a_thread_the_mc_has_no_provider_for_is_not_switched_by_the_first_send() {
    let hub = clustered(hal_c2_shell::Launch::default());
    hub.mc.set_ready(&hub.engine, true);
    let mut row = thread_row("t1");
    row[3]
        .as_object_mut()
        .map(|fields| fields.remove("modelSelection"));
    shell(&hub, vec![project(json!({})), row]);
    open(&hub, "t1");
    providers(&hub);
    send(&hub, "hello");
    let sent = commands(&hub);
    assert_eq!(sent.len(), 1, "{sent:?}");
    assert_eq!(sent[0]["type"], "message.dispatch");
    assert_eq!(sent[0]["modelSelection"]["instanceId"], "codex");
}
