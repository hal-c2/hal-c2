//! `usage`: the usage page's reads and limits, merged across environments
//! (UsageController.cpp, features/usage/), against a fake MC and a clock the
//! test moves.

use std::cell::Cell;
use std::path::PathBuf;
use std::rc::Rc;

use chrono::{DateTime, Utc};
use hal_c2_shell::Launch;
use hal_c2_shell::controllers::usage::{Usage, Zone};
use hal_c2_shell::controllers::usage_prices::{Environment, set_environments};
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::McError;
use serde_json::json;

use crate::Hub;

fn at(text: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(text)
        .unwrap()
        .with_timezone(&Utc)
}

fn environments(hub: &Hub, list: &[(&str, &str, bool)]) {
    set_environments(
        &hub.engine,
        list.iter()
            .map(|(id, label, online)| Environment {
                id: id.to_string(),
                label: label.to_string(),
                online: *online,
            })
            .collect(),
    );
}

/// A hub at 2026-03-10 12:00 UTC, in UTC, over `list`, and the clock the test
/// moves.
fn rig(list: &[(&str, &str, bool)]) -> (Hub, Rc<Cell<i64>>) {
    let hub = Hub::new();
    environments(&hub, list);
    let now = Rc::new(Cell::new(at("2026-03-10T12:00:00Z").timestamp()));
    let clock = now.clone();
    hub.with_controller::<Usage, _>(|u, _| {
        u.set_clock(move || DateTime::from_timestamp(clock.get(), 0).unwrap());
        u.set_zone(Zone::fixed("UTC", 0));
    });
    (hub, now)
}

fn usage(hub: &Hub) -> Json {
    hub.published("usage")
}

fn open(hub: &Hub, metric: &str) {
    hub.dispatch("usage.metric", json!({"metric": metric}));
    hub.dispatch("usage.open", json!({}));
}

fn count(hub: &Hub, method: &str) -> usize {
    hub.mc.methods().iter().filter(|m| *m == method).count()
}

fn bucket(provider: &str, model: &str, day: &str, tokens: u64, cost: f64) -> Json {
    json!({
        "provider": provider, "model": model, "day": day, "costUsd": cost,
        "records": 1, "unpricedRecords": 0,
        "totals": {"uncachedInputTokens": tokens, "cachedInputTokens": 0, "outputTokens": 0, "cacheCreationTokens": 0},
    })
}

fn source(provider: &str, home: &str, sessions: u64) -> Json {
    json!({
        "status": "ok", "distinctSessions": sessions,
        "fingerprint": {"hostId": "h", "provider": provider, "resolvedHomePath": home, "volumeId": "v"},
    })
}

fn summary(read_at: &str, sources: Vec<Json>, buckets: Vec<Json>) -> Json {
    json!({"contractVersion": 5, "readAt": read_at, "sources": sources, "buckets": buckets})
}

fn provider(driver: &str, email: &str, used: f64, checked: &str) -> Json {
    json!({
        "driver": driver, "instanceId": driver, "auth": {"email": email},
        "usageLimits": {"checkedAt": checked, "windows": [
            {"kind": "session", "id": "5h", "label": "Session", "usedPercent": used, "resetsAt": "2026-03-10T15:00:00Z"},
        ]},
    })
}

#[test]
fn the_page_reads_nothing_until_it_is_opened_and_asks_over_the_window() {
    let (hub, _) = rig(&[("env-1", "", true)]);
    hub.dispatch("usage.metric", json!({"metric": "cost"}));
    assert_eq!(count(&hub, "server.getUsageSummary"), 0);
    assert_eq!(usage(&hub)["open"], false);

    hub.dispatch("usage.open", json!({}));
    let index = hub.mc.pending("server.getUsageSummary").unwrap();
    let window = hub.mc.calls.borrow()[index].2.clone();
    assert_eq!(window["resolution"], "day");
    assert_eq!(window["sinceDay"], "2026-02-09");
    assert_eq!(window["untilDay"], "2026-03-10");
    assert_eq!(window["timeZone"], "UTC");
    assert_eq!(usage(&hub)["message"], "Reading session history…");
    assert_eq!(usage(&hub)["environments"][0]["status"], "scanning");
}

#[test]
fn a_one_day_window_is_the_past_twenty_four_hours_by_the_hour() {
    let (hub, now) = rig(&[("env-1", "", true)]);
    now.set(at("2026-03-10T12:00:42Z").timestamp());
    hub.dispatch("usage.window", json!({"days": 1}));
    open(&hub, "cost");
    let index = hub.mc.pending("server.getUsageSummary").unwrap();
    let window = hub.mc.calls.borrow()[index].2.clone();
    assert_eq!(window["resolution"], "hour");
    assert_eq!(window["sinceTime"], "2026-03-09T12:00:00.000Z");
    assert_eq!(window["untilTime"], "2026-03-10T12:00:00.000Z");
}

#[test]
fn environments_merge_and_a_shared_transcript_directory_counts_once() {
    let (hub, _) = rig(&[("env-1", "Laptop", true), ("env-2", "Server", true)]);
    open(&hub, "cost");
    let shared = source("codex", "/home/a/.codex", 3);
    let first = summary(
        "2026-03-10T11:00:00Z",
        vec![shared.clone(), source("claude", "/home/a/.claude", 2)],
        vec![
            bucket("codex", "gpt", "2026-03-09", 1000, 1.5),
            bucket("claude", "opus", "2026-03-10", 500, 2.0),
        ],
    );
    // Read later, of the same directory: it owns the directory, so the older
    // read's codex numbers are left out.
    let second = summary(
        "2026-03-10T11:30:00Z",
        vec![shared],
        vec![bucket("codex", "gpt", "2026-03-09", 4000, 6.0)],
    );
    hub.mc
        .answer_on(&hub.engine, "env-1", "server.getUsageSummary", Ok(first));
    assert_eq!(usage(&hub)["environments"][1]["status"], "scanning");
    // The one still scanning does not hold the other back.
    assert_eq!(usage(&hub)["summary"]["costUsd"], 3.5);
    hub.mc
        .answer_on(&hub.engine, "env-2", "server.getUsageSummary", Ok(second));

    let page = usage(&hub);
    let summary = &page["summary"];
    assert_eq!(summary["costUsd"], 8.0);
    assert_eq!(summary["totalTokens"], 4500.0);
    assert_eq!(summary["sessions"], 5.0);
    let providers: Vec<&str> = summary["providers"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["id"].as_str().unwrap())
        .collect();
    assert_eq!(providers, ["codex", "claude"]);
    assert_eq!(summary["periods"][0]["key"], "2026-03-10");
    assert_eq!(summary["periods"][0]["label"], "Mar 10");
    // Every day of the window is charted, the quiet ones too.
    assert_eq!(summary["chart"].as_array().unwrap().len(), 30);
    assert_eq!(
        page["notices"][0],
        "Counted once across environments sharing a transcript directory: Laptop: /home/a/.codex"
    );
    assert_eq!(page["scanning"], false);
}

#[test]
fn an_environment_on_an_older_contract_or_failing_is_left_out_and_named() {
    let (hub, _) = rig(&[
        ("a", "Old", true),
        ("b", "Broken", true),
        ("c", "Fine", true),
    ]);
    open(&hub, "tokens");
    let mut old = summary(
        "2026-03-10T11:00:00Z",
        vec![source("codex", "/o", 1)],
        vec![bucket("codex", "g", "2026-03-10", 9, 9.0)],
    );
    old["contractVersion"] = json!(3);
    hub.mc
        .answer_on(&hub.engine, "a", "server.getUsageSummary", Ok(old));
    hub.mc.answer_on(
        &hub.engine,
        "b",
        "server.getUsageSummary",
        Err(McError::new("boom")),
    );
    let fine = summary(
        "2026-03-10T11:00:00Z",
        vec![source("codex", "/f", 1)],
        vec![bucket("codex", "g", "2026-03-10", 7, 1.0)],
    );
    hub.mc
        .answer_on(&hub.engine, "c", "server.getUsageSummary", Ok(fine));

    let page = usage(&hub);
    assert_eq!(page["summary"]["totalTokens"], 7.0);
    let notices: Vec<&str> = page["notices"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| n.as_str().unwrap())
        .collect();
    assert!(
        notices.contains(&"Old runs an older server version and is excluded from totals."),
        "{notices:?}"
    );
    assert!(
        notices.contains(&"Broken could not report usage."),
        "{notices:?}"
    );
    let statuses: Vec<&str> = page["environments"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["status"].as_str().unwrap())
        .collect();
    assert_eq!(statuses, ["outdated", "failed", "ready"]);
}

#[test]
fn an_offline_environment_is_not_asked_and_asked_when_it_comes_back() {
    let (hub, _) = rig(&[("a", "A", true), ("b", "B", false)]);
    open(&hub, "cost");
    assert!(hub.mc.pending_on("a", "server.getUsageSummary").is_some());
    assert!(hub.mc.pending_on("b", "server.getUsageSummary").is_none());
    assert_eq!(usage(&hub)["environments"][1]["status"], "offline");

    environments(&hub, &[("a", "A", true), ("b", "B", true)]);
    hub.mc.set_ready(&hub.engine, true);
    assert!(hub.mc.pending_on("b", "server.getUsageSummary").is_some());
    assert_eq!(usage(&hub)["environments"][1]["status"], "scanning");
}

#[test]
fn an_answer_to_an_older_window_is_dropped() {
    let (hub, _) = rig(&[("env-1", "", true)]);
    open(&hub, "cost");
    let stale = hub.mc.pending("server.getUsageSummary").unwrap();
    hub.dispatch("usage.window", json!({"days": 7}));
    let late = summary(
        "2026-03-10T11:00:00Z",
        vec![source("codex", "/c", 1)],
        vec![bucket("codex", "g", "2026-03-10", 1, 1.0)],
    );
    hub.mc.reply(&hub.engine, stale, Ok(late));
    assert_eq!(usage(&hub)["summary"], Json::Null);
    assert_eq!(usage(&hub)["windowDays"], 7);
    let fresh = hub.mc.pending("server.getUsageSummary").unwrap();
    assert_ne!(fresh, stale);
    assert_eq!(hub.mc.calls.borrow()[fresh].2["sinceDay"], "2026-03-04");
}

#[test]
fn the_refresh_fetches_prices_first_and_reads_again() {
    let (hub, _) = rig(&[("env-1", "", true)]);
    open(&hub, "cost");
    hub.mc
        .answer(&hub.engine, "server.getUsageSummary", Ok(json!({})));
    assert_eq!(usage(&hub)["refreshing"], false);
    hub.dispatch("usage.refresh", json!({}));
    assert_eq!(usage(&hub)["refreshing"], true);
    assert_eq!(count(&hub, "server.getUsageSummary"), 1);
    hub.mc
        .answer(&hub.engine, "server.refreshUsageRates", Ok(json!({})));
    assert_eq!(count(&hub, "server.getUsageSummary"), 2);
    // Pressing it again while it works asks nothing more.
    hub.dispatch("usage.refresh", json!({}));
    assert_eq!(count(&hub, "server.refreshUsageRates"), 1);
    hub.mc
        .answer(&hub.engine, "server.getUsageSummary", Ok(json!({})));
    assert_eq!(usage(&hub)["refreshing"], false);
}

#[test]
fn limits_pool_the_accounts_of_a_driver_and_follow_the_config() {
    let (hub, _) = rig(&[("a", "Laptop", true), ("b", "Server", true)]);
    open(&hub, "limits");
    let followed: Vec<Json> = hub
        .mc
        .subscriptions()
        .into_iter()
        .map(|(_, s)| s)
        .filter(|s| s["type"] == "config" && s.get("usageLimitsCommand").is_none())
        .collect();
    assert_eq!(followed.len(), 2);
    hub.mc.frame(&hub.engine, "config", "a", json!({"t": "config.providers", "providers": [provider("codex", "me@x.io", 30.0, "2026-03-10T11:00:00Z")]}));
    // The same account seen from the other environment, read later, wins.
    hub.mc.frame(&hub.engine, "config", "b", json!({"t": "config.providers", "providers": [provider("codex", "ME@x.io", 50.0, "2026-03-10T11:30:00Z"), provider("claudeAgent", "", 10.0, "2026-03-10T11:30:00Z")]}));
    let limits = usage(&hub)["limits"].clone();
    let pools = limits["pools"].as_array().unwrap();
    assert_eq!(pools.len(), 2);
    assert_eq!(pools[0]["driver"], "codex");
    assert_eq!(pools[0]["label"], "Codex");
    assert_eq!(pools[0]["windows"][0]["remainingPercent"], 50);
    assert_eq!(
        pools[0]["windows"][0]["accounts"].as_array().unwrap().len(),
        1
    );
    assert_eq!(pools[1]["driver"], "claudeAgent");
}

#[test]
fn limits_are_asked_again_only_after_five_minutes_unless_the_user_asks() {
    let (hub, now) = rig(&[("env-1", "", true)]);
    open(&hub, "limits");
    assert_eq!(count(&hub, "server.refreshProviders"), 1);
    hub.mc.answer(
        &hub.engine,
        "server.refreshProviders",
        Ok(json!({"providers": []})),
    );
    // Showing again, within five minutes, asks nothing.
    hub.dispatch("usage.metric", json!({"metric": "cost"}));
    hub.dispatch("usage.metric", json!({"metric": "limits"}));
    assert_eq!(count(&hub, "server.refreshProviders"), 1);
    now.set(now.get() + 301);
    hub.dispatch("usage.metric", json!({"metric": "cost"}));
    hub.dispatch("usage.metric", json!({"metric": "limits"}));
    assert_eq!(count(&hub, "server.refreshProviders"), 2);
    hub.mc.answer(
        &hub.engine,
        "server.refreshProviders",
        Ok(json!({"providers": []})),
    );
    // The user's own refresh is never throttled.
    hub.dispatch("usage.refresh", json!({}));
    assert_eq!(count(&hub, "server.refreshProviders"), 3);
}

#[test]
fn a_banked_reset_credit_is_spent_where_it_was_read_and_says_what_came_of_it() {
    let (hub, _) = rig(&[("env-1", "", true)]);
    open(&hub, "limits");
    hub.mc
        .answer(&hub.engine, "server.refreshProviders", Ok(json!({})));
    let mut codex = provider("codex", "me@x.io", 80.0, "2026-03-10T11:00:00Z");
    codex["usageLimits"]["resetCredits"] =
        json!({"availableCount": 2, "nextExpiresAt": "2026-04-01T00:00:00Z"});
    hub.mc.frame(
        &hub.engine,
        "config",
        "env-1",
        json!({"t": "config.providers", "providers": [codex]}),
    );
    let credit = usage(&hub)["limits"]["pools"][0]["credits"][0].clone();
    assert_eq!(credit["available"], 2);
    hub.dispatch("usage.resetCredit", json!({"key": credit["key"]}));
    assert_eq!(
        usage(&hub)["limits"]["pools"][0]["credits"][0]["busy"],
        true
    );
    // Twice is once.
    hub.dispatch("usage.resetCredit", json!({"key": credit["key"]}));
    assert_eq!(count(&hub, "provider.consumeResetCredit"), 1);
    let index = hub.mc.pending("provider.consumeResetCredit").unwrap();
    assert_eq!(
        hub.mc.calls.borrow()[index].2,
        json!({"instanceId": "codex"})
    );
    hub.mc
        .reply(&hub.engine, index, Ok(json!({"outcome": "reset"})));
    let credit = usage(&hub)["limits"]["pools"][0]["credits"][0].clone();
    assert_eq!(credit["busy"], false);
    assert_eq!(
        credit["status"],
        "Reset applied. Your windows have cleared."
    );
    // The windows are read again.
    assert_eq!(count(&hub, "server.refreshProviders"), 2);
}

#[test]
fn the_metric_and_window_are_kept_on_this_device() {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("hub-usage-kept");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let launch = || Launch {
        config_dir: Some(dir.clone()),
        ..Launch::default()
    };
    let first = Hub::with(launch());
    first.dispatch("usage.metric", json!({"metric": "tokens"}));
    first.dispatch("usage.window", json!({"days": 90}));
    first.dispatch("usage.metric", json!({"metric": "nonsense"}));
    first.dispatch("usage.window", json!({"days": 5}));
    assert_eq!(usage(&first)["metric"], "tokens");
    assert_eq!(usage(&first)["windowDays"], 90);

    let second = Hub::with(launch());
    assert_eq!(usage(&second)["metric"], "tokens");
    assert_eq!(usage(&second)["windowDays"], 90);
}

#[test]
fn an_environment_that_is_not_there_cannot_be_chosen() {
    let (hub, _) = rig(&[("a", "A", true), ("b", "B", true)]);
    open(&hub, "cost");
    hub.dispatch("usage.environment", json!({"id": "nope"}));
    assert_eq!(usage(&hub)["environmentId"], "");
    hub.dispatch("usage.environment", json!({"id": "b"}));
    assert_eq!(usage(&hub)["environmentId"], "b");
    // Only b is read now; a is no longer chosen.
    assert_eq!(count(&hub, "server.getUsageSummary"), 3);
    assert_eq!(hub.mc.calls.borrow().last().unwrap().0, "b");
}

#[test]
fn nothing_connected_says_so() {
    let (hub, _) = rig(&[]);
    open(&hub, "cost");
    assert_eq!(
        usage(&hub)["message"],
        "Connect an environment to see usage."
    );
    hub.dispatch("usage.metric", json!({"metric": "limits"}));
    assert_eq!(
        usage(&hub)["message"],
        "Connect an environment to see limits."
    );
}
