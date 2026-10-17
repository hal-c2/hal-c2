//! Settings → Integrations → Slack (`slackSettings`).

use std::cell::RefCell;
use std::rc::Rc;

use hal_c2_shell::bridge::Bridge;
use proptest::prelude::*;
use serde_json::json;

use crate::Hub;
use crate::page::{answer, count, failure, hub_with, open, toasts};

const SECTION: &str = "/settings/integrations";

fn status(state: &str) -> serde_json::Value {
    json!({"t": "slack", "status": {"state": state, "team": "Acme", "bot": "hal", "tokensSet": true}})
}

fn opened() -> Hub {
    let hub = hub_with(json!({"settings": {}}));
    open(&hub, SECTION);
    hub
}

fn state(hub: &Hub) -> serde_json::Value {
    hub.published("slackSettings")
}

#[test]
fn slack_is_followed_only_while_its_section_shows() {
    let hub = hub_with(json!({"settings": {}}));
    assert_eq!(state(&hub), json!({"open": false}));
    assert!(
        hub.mc
            .subscriptions()
            .iter()
            .all(|(_, s)| s["type"] != "slack")
    );
    open(&hub, SECTION);
    assert!(
        hub.mc
            .subscriptions()
            .iter()
            .any(|(_, s)| s["type"] == "slack")
    );
    assert_eq!(state(&hub)["loaded"], false);
    hub.mc.frame(&hub.engine, "slack", "", status("connected"));
    let shown = state(&hub);
    assert_eq!(shown["loaded"], true);
    assert_eq!(shown["state"], "connected");
    assert_eq!(shown["team"], "Acme");
    assert_eq!(shown["tokensSet"], true);
    assert_eq!(shown["editable"], true);
}

#[test]
fn connecting_needs_both_tokens_and_waits_for_the_answer() {
    let hub = opened();
    // Nothing is sent until Slack is followed.
    hub.dispatch(
        "slackSettings.connect",
        json!({"botToken": "b", "appToken": "a"}),
    );
    assert_eq!(count(&hub, "slack.connect"), 0);
    hub.mc.frame(&hub.engine, "slack", "", status("off"));

    hub.dispatch(
        "slackSettings.connect",
        json!({"botToken": "b", "appToken": " "}),
    );
    assert_eq!(count(&hub, "slack.connect"), 0);
    assert_eq!(
        state(&hub)["error"],
        "Enter both the bot token and the app token."
    );

    hub.dispatch(
        "slackSettings.connect",
        json!({"botToken": " b ", "appToken": "a"}),
    );
    assert_eq!(state(&hub)["pending"], "connect");
    assert_eq!(
        crate::page::last(&hub, "env-1", "slack.connect"),
        json!({"botToken": "b", "appToken": "a"})
    );
    // One change at a time.
    hub.dispatch("slackSettings.disconnect", json!({}));
    assert_eq!(count(&hub, "slack.disconnect"), 0);
    answer(
        &hub,
        "env-1",
        "slack.connect",
        Ok(status("connecting")["status"].clone()),
    );
    let shown = state(&hub);
    assert_eq!(shown["pending"], "");
    assert_eq!(shown["state"], "connecting");
}

#[test]
fn a_refusal_is_the_error_and_a_newer_status_beats_the_answer() {
    let hub = opened();
    hub.mc.frame(&hub.engine, "slack", "", status("off"));
    hub.dispatch(
        "slackSettings.connect",
        json!({"botToken": "b", "appToken": "a"}),
    );
    answer(&hub, "env-1", "slack.connect", Err(failure("invalid_auth")));
    assert_eq!(state(&hub)["error"], "invalid_auth");

    hub.dispatch(
        "slackSettings.connect",
        json!({"botToken": "b", "appToken": "a"}),
    );
    // The MC's push comes before the call's answer, and is the newer.
    hub.mc.frame(&hub.engine, "slack", "", status("connected"));
    answer(
        &hub,
        "env-1",
        "slack.connect",
        Ok(status("off")["status"].clone()),
    );
    let shown = state(&hub);
    assert_eq!(shown["state"], "connected");
    assert_eq!(shown["pending"], "");
}

#[test]
fn a_failed_follow_says_why_and_retry_follows_again() {
    let hub = opened();
    hub.mc.frame(&hub.engine, "slack", "", status("connected"));
    hub.mc.frame(
        &hub.engine,
        "slack",
        "",
        json!({"t": "error", "reason": "Slack is down"}),
    );
    let shown = state(&hub);
    assert_eq!(shown["failed"], true);
    assert_eq!(shown["error"], "Slack is down");
    assert_eq!(shown["loaded"], false);
    assert!(
        hub.mc
            .subscriptions()
            .iter()
            .all(|(_, s)| s["type"] != "slack")
    );
    // Nothing else works until it is followed again.
    hub.dispatch("slackSettings.disconnect", json!({}));
    assert_eq!(count(&hub, "slack.disconnect"), 0);
    hub.dispatch("slackSettings.retry", json!({}));
    assert!(
        hub.mc
            .subscriptions()
            .iter()
            .any(|(_, s)| s["type"] == "slack")
    );
    assert_eq!(state(&hub)["failed"], false);
}

#[test]
fn the_manifest_goes_to_the_clipboard() {
    let hub = opened();
    hub.mc.frame(&hub.engine, "slack", "", status("off"));
    let copied = Rc::new(RefCell::new(Vec::<String>::new()));
    let sink = copied.clone();
    Bridge::of(&hub.engine).set_clipboard_writer(&hub.engine, move |text| {
        sink.borrow_mut().push(text.to_owned());
    });
    hub.dispatch("slackSettings.copyManifest", json!({}));
    assert_eq!(state(&hub)["pending"], "manifest");
    answer(
        &hub,
        "env-1",
        "slack.manifest",
        Ok(json!({"manifest": "{\"a\":1}"})),
    );
    assert_eq!(*copied.borrow(), ["{\"a\":1}"]);
    assert!(
        toasts(&hub)
            .iter()
            .any(|(t, _)| t == "Slack app manifest copied")
    );

    hub.dispatch("slackSettings.copyManifest", json!({}));
    answer(&hub, "env-1", "slack.manifest", Err(failure("offline")));
    assert!(
        toasts(&hub)
            .iter()
            .any(|(t, d)| t == "Could not copy the Slack app manifest" && d == "offline")
    );
    assert_eq!(copied.borrow().len(), 1);
}

#[test]
fn leaving_the_section_stops_following_and_forgets() {
    let hub = opened();
    hub.mc.frame(&hub.engine, "slack", "", status("connected"));
    hub.dispatch("settings.navigate", json!({"to": "/settings/general"}));
    assert_eq!(state(&hub), json!({"open": false}));
    assert!(
        hub.mc
            .subscriptions()
            .iter()
            .all(|(_, s)| s["type"] != "slack")
    );
    open(&hub, SECTION);
    assert_eq!(state(&hub)["loaded"], false);
}

// -- Order: the answers and pushes may come in any order -------------------

#[derive(Clone, Debug)]
enum Step {
    Push(&'static str),
    Connect,
    Disconnect,
    Answer(bool),
    Fail,
    Retry,
    Leave,
    Enter,
}

fn step() -> impl Strategy<Value = Step> {
    prop_oneof![
        prop_oneof![Just("off"), Just("connected"), Just("failed")].prop_map(Step::Push),
        Just(Step::Connect),
        Just(Step::Disconnect),
        any::<bool>().prop_map(Step::Answer),
        Just(Step::Fail),
        Just(Step::Retry),
        Just(Step::Leave),
        Just(Step::Enter),
    ]
}

proptest! {
    /// Whatever the order of pushes, answers and visits, a change shows as
    /// pending only while a call of it is unanswered, a page that is left
    /// shows nothing, and a failed follow is never also loaded.
    #[test]
    fn pending_means_a_change_is_unanswered(steps in proptest::collection::vec(step(), 1..24)) {
        let hub = opened();
        let mut shown = true;
        for step in steps {
            match step {
                Step::Push(s) => hub.mc.frame(&hub.engine, "slack", "", status(s)),
                Step::Connect => hub.dispatch("slackSettings.connect", json!({"botToken": "b", "appToken": "a"})),
                Step::Disconnect => hub.dispatch("slackSettings.disconnect", json!({})),
                Step::Answer(ok) => {
                    for method in ["slack.connect", "slack.disconnect"] {
                        if let Some(i) = hub.mc.pending_on("env-1", method) {
                            let result = if ok { Ok(status("off")["status"].clone()) } else { Err(failure("no")) };
                            hub.mc.reply(&hub.engine, i, result);
                        }
                    }
                }
                Step::Fail => hub.mc.frame(&hub.engine, "slack", "", json!({"t": "error", "reason": "down"})),
                Step::Retry => hub.dispatch("slackSettings.retry", json!({})),
                Step::Leave => {
                    hub.dispatch("settings.navigate", json!({"to": "/settings/general"}));
                    shown = false;
                }
                Step::Enter => {
                    open(&hub, SECTION);
                    shown = true;
                }
            }
            let now = state(&hub);
            if !shown {
                prop_assert_eq!(now, json!({"open": false}));
                continue;
            }
            let in_flight = ["slack.connect", "slack.disconnect"]
                .iter()
                .any(|m| hub.mc.pending_on("env-1", m).is_some());
            if now["pending"].as_str().is_some_and(|p| !p.is_empty()) {
                prop_assert!(in_flight);
            }
            prop_assert!(!(now["loaded"] == true && now["failed"] == true));
        }
    }
}
