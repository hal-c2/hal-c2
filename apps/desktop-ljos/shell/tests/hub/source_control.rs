//! Settings → Source Control (`sourceControlSettings`).

use proptest::prelude::*;
use serde_json::json;

use crate::Hub;
use crate::page::{accept_write, answer, count, failure, hub_with, open, toasts, written};

const SECTION: &str = "/settings/source-control";
const DISCOVER: &str = "server.discoverSourceControl";

fn state(hub: &Hub) -> serde_json::Value {
    hub.published("sourceControlSettings")
}

fn opened() -> Hub {
    let hub = hub_with(json!({"settings": {}, "providers": []}));
    open(&hub, SECTION);
    hub
}

fn found() -> serde_json::Value {
    json!({
        "versionControlSystems": [{"kind": "git", "label": "Git", "implemented": true, "version": {"_tag": "Some", "value": "2.50"}}],
        "sourceControlProviders": []
    })
}

#[test]
fn opening_scans_once_and_the_section_forgets_when_left() {
    let hub = opened();
    assert_eq!(count(&hub, DISCOVER), 1);
    assert_eq!(state(&hub)["discovery"]["status"], "loading");
    answer(&hub, "env-1", DISCOVER, Ok(found()));
    assert_eq!(state(&hub)["discovery"]["status"], "ready");
    assert_eq!(
        state(&hub)["discovery"]["versionControl"][0]["label"],
        "Git"
    );

    hub.dispatch("settings.navigate", json!({"to": "/settings/general"}));
    assert_eq!(state(&hub), json!({"open": false}));
    open(&hub, SECTION);
    assert_eq!(count(&hub, DISCOVER), 2);
}

#[test]
fn a_signed_out_hosts_summary_sets_the_tool_it_names_in_code() {
    let hub = opened();
    answer(
        &hub,
        "env-1",
        DISCOVER,
        Ok(json!({
            "versionControlSystems": [],
            "sourceControlProviders": [{"kind": "github", "label": "GitHub", "status": "available",
                "executable": "gh", "auth": {"status": "unauthenticated"}}]
        })),
    );
    let github = state(&hub)["discovery"]["providers"][0].clone();
    assert_eq!(github["authLabel"], "Not authenticated");
    assert_eq!(github["authWarning"], true);
    let summary = github["summary"].as_str().unwrap();
    assert!(summary.starts_with("GitHub is not authenticated on this server. Sign in"));
    assert!(summary.contains("using the `gh` tool"), "{summary}");
}

#[test]
fn a_failed_scan_replaces_what_an_older_one_found() {
    let hub = opened();
    answer(&hub, "env-1", DISCOVER, Ok(found()));
    hub.dispatch("sourceControlSettings.scan", json!({}));
    assert_eq!(state(&hub)["discovery"]["scanning"], true);
    answer(&hub, "env-1", DISCOVER, Err(failure("")));
    let discovery = state(&hub)["discovery"].clone();
    assert_eq!(discovery["status"], "error");
    assert_eq!(discovery["message"], "The scan failed.");
    assert_eq!(discovery["versionControl"], json!([]));
}

#[test]
fn the_newest_scan_wins_whatever_order_they_answer_in() {
    let hub = opened();
    hub.dispatch("sourceControlSettings.scan", json!({}));
    answer(&hub, "env-1", DISCOVER, Err(failure("old")));
    assert_eq!(state(&hub)["discovery"]["scanning"], true);
    assert_eq!(state(&hub)["discovery"]["status"], "loading");
    answer(&hub, "env-1", DISCOVER, Ok(found()));
    assert_eq!(state(&hub)["discovery"]["status"], "ready");
}

#[test]
fn the_rows_write_the_environment_defaults() {
    let hub = opened();
    hub.dispatch("sourceControlSettings.autoPull", json!({"enabled": true}));
    assert_eq!(written(&hub)["defaultAutoPull"], true);
    accept_write(&hub, 2);
    assert_eq!(state(&hub)["autoPull"]["value"], true);

    hub.dispatch(
        "sourceControlSettings.mergeMethod",
        json!({"method": "squash"}),
    );
    assert_eq!(written(&hub)["pullRequestMergeMethod"], "squash");
    accept_write(&hub, 3);
    assert_eq!(state(&hub)["mergeMethod"]["value"], "squash");
    hub.dispatch(
        "sourceControlSettings.mergeMethod",
        json!({"method": "last"}),
    );
    accept_write(&hub, 4);
    assert_eq!(state(&hub)["mergeMethod"]["value"], "last");

    hub.dispatch("sourceControlSettings.templates", json!({"enabled": false}));
    assert_eq!(
        written(&hub)["sourceControlWritingStyle"]["followChangeRequestTemplates"],
        false
    );
    accept_write(&hub, 5);
    assert_eq!(state(&hub)["templates"]["value"], false);
}

#[test]
fn writing_style_ignores_unknown_modes_and_trims_instructions() {
    let hub = opened();
    let before = crate::page::writes(&hub);
    hub.dispatch(
        "sourceControlSettings.writingMode",
        json!({"mode": "nonsense"}),
    );
    assert_eq!(crate::page::writes(&hub), before);
    hub.dispatch(
        "sourceControlSettings.instructions",
        json!({"text": "  be terse \n"}),
    );
    assert_eq!(
        written(&hub)["sourceControlWritingStyle"]["customInstructions"],
        "be terse"
    );
    accept_write(&hub, 2);
    assert_eq!(state(&hub)["writingStyle"]["instructions"], "be terse");
    assert_eq!(state(&hub)["writingStyle"]["dirty"], true);
}

#[test]
fn the_fetch_interval_is_the_environments_and_resets() {
    let hub = opened();
    hub.dispatch(
        "sourceControlSettings.fetchInterval",
        json!({"seconds": 120}),
    );
    assert_eq!(
        written(&hub)["backgroundActivity"]["overrides"]["automaticGitFetchInterval"],
        120_000
    );
    accept_write(&hub, 2);
    assert_eq!(state(&hub)["fetchInterval"]["seconds"], 120);
    assert_eq!(state(&hub)["fetchInterval"]["custom"], true);
    hub.dispatch("sourceControlSettings.resetFetchInterval", json!({}));
    accept_write(&hub, 3);
    assert_eq!(state(&hub)["fetchInterval"]["custom"], false);
}

#[test]
fn a_writer_model_that_cannot_write_is_refused_with_a_toast() {
    let hub = hub_with(json!({
        "settings": {},
        "providers": [{
            "instanceId": "codex", "driver": "codex", "enabled": true, "installed": true,
            "status": "ready", "auth": {"status": "authenticated"},
            "models": [{"slug": "gpt-x", "name": "GPT X"}]
        }]
    }));
    open(&hub, SECTION);
    let before = crate::page::writes(&hub);
    hub.dispatch(
        "sourceControlSettings.pickWriterModel",
        json!({"key": "ghost:model"}),
    );
    assert_eq!(crate::page::writes(&hub), before);
    assert!(
        toasts(&hub)
            .iter()
            .any(|(t, _)| t == "Source control writer model not saved")
    );
}

#[derive(Clone, Debug)]
enum Step {
    Scan,
    Answer(usize, bool),
    Leave,
    Enter,
}

fn step() -> impl Strategy<Value = Step> {
    prop_oneof![
        Just(Step::Scan),
        (0usize..30, any::<bool>()).prop_map(|(i, ok)| Step::Answer(i, ok)),
        Just(Step::Leave),
        Just(Step::Enter),
    ]
}

proptest! {
    /// Scans are answered in any order; the page is scanning exactly while
    /// the latest scan of the open page is unanswered.
    #[test]
    fn scanning_means_the_latest_scan_is_unanswered(steps in proptest::collection::vec(step(), 1..24)) {
        let hub = opened();
        let mut shown = true;
        for step in steps {
            match step {
                Step::Scan => hub.dispatch("sourceControlSettings.scan", json!({})),
                Step::Answer(i, ok) => {
                    let asked = hub.mc.calls.borrow().len();
                    let result = if ok { Ok(found()) } else { Err(failure("no")) };
                    hub.mc.reply(&hub.engine, i % asked, result);
                }
                Step::Leave => {
                    hub.dispatch("settings.navigate", json!({"to": "/settings/general"}));
                    shown = false;
                }
                Step::Enter => {
                    open(&hub, SECTION);
                    shown = true;
                }
            }
            if !shown {
                prop_assert_eq!(state(&hub), json!({"open": false}));
                continue;
            }
            let calls = hub.mc.calls.borrow();
            let latest = calls.iter().rposition(|(_, m, _)| m == DISCOVER);
            drop(calls);
            if let Some(latest) = latest {
                let scanning = state(&hub)["discovery"]["scanning"] == true;
                prop_assert_eq!(scanning, hub.mc.is_pending(latest));
            }
        }
    }
}
