//! A shell that started without an MC and was opened at one since, as the
//! welcome wizard does (`hal_c2_shell::open`): its shell store is made then,
//! and every controller, active from the start, must follow it as one that
//! started with the MC does.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use hal_c2_shell::Launch;
use hal_c2_shell::controllers::threads;
use hal_c2_shell::json::Json;
use hal_c2_shell::session::Session;
use hal_c2_shell::store;
use proptest::prelude::*;
use serde_json::json;

use crate::Hub;

const ORIGIN: &str = "http://127.0.0.1:1";
const AT: &str = "2026-03-01T00:00:00Z";

/// A hub that started with the MC at `ORIGIN`, over a cache of its own.
fn clustered() -> (Hub, tempfile::TempDir) {
    let dir = tempfile::tempdir().expect("a cache directory");
    let hub = Hub::with(Launch {
        mc_origin: Some(ORIGIN.into()),
        cache_dir: Some(dir.path().to_owned()),
        ..Launch::default()
    });
    (hub, dir)
}

/// A hub that started with no MC, over a cache of its own.
fn late() -> (Hub, tempfile::TempDir) {
    let dir = tempfile::tempdir().expect("a cache directory");
    let hub = Hub::with(Launch {
        cache_dir: Some(dir.path().to_owned()),
        ..Launch::default()
    });
    (hub, dir)
}

/// Opens the hub at the MC, as pairing does.
fn open(hub: &Hub) {
    hal_c2_shell::open(
        &hub.engine,
        &Session {
            origin: ORIGIN.into(),
            token: "session".into(),
            ..Session::default()
        },
    )
    .expect("the MC opens");
    // The store's own opening waits for the controllers to be free.
    hub.advance(0);
}

/// The cluster `env-1` (Laptop) and `env-2` (Studio) make, with a project
/// and two threads on `env-1`.
fn cluster(hub: &Hub) {
    let mc = |name: &str, environment: &str, label: &str| {
        json!({"mc": name, "online": true, "epoch": "e", "rev": 1,
            "environment": {"environmentId": environment, "label": label}})
    };
    let thread = |id: &str| {
        json!(["a", id, "thread", {"id": id, "projectId": "p1", "title": id,
            "createdAt": AT, "updatedAt": AT, "worktreePath": "/work/tree",
            "modelSelection": {"instanceId": "claude", "model": "m"}}])
    };
    hub.mc.set_ready(&hub.engine, true);
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell",
        "mcs": [mc("a", "env-1", "Laptop"), mc("b", "env-2", "Studio")],
        "rows": [
            ["a", "p1", "project", {"id": "p1", "title": "Alpha", "workspaceRoot": "/work",
                "createdAt": AT, "updatedAt": AT}],
            thread("t1"),
            thread("t2"),
        ]}),
    );
    hub.advance(0);
}

/// `value` with the ids a shell makes up (a draft's) made alike.
fn unmade(value: Json) -> Json {
    let made = |s: &str| {
        let id = s.rsplit(':').next().unwrap_or(s);
        id.len() == 36 && id.matches('-').count() == 4
    };
    match value {
        Json::String(s) if made(&s) => "<id>".into(),
        Json::Array(items) => Json::Array(items.into_iter().map(unmade).collect()),
        Json::Object(fields) => {
            Json::Object(fields.into_iter().map(|(k, v)| (k, unmade(v))).collect())
        }
        other => other,
    }
}

/// The keys the pages publish only while they are open (they are asked
/// again when one opens, so a closed page's state is not compared), and the
/// wizard's, which a shell paired from it keeps showing.
const PAGES: [(&str, &str, &str); 3] = [
    ("usage", "usage.open", "{}"),
    ("pullRequestList", "pullRequests.open", "{}"),
    (
        "providerSettings",
        "settings.navigate",
        r#"{"to": "/settings/providers"}"#,
    ),
];

/// What the controllers publish, by key, but for `skipped`.
fn published(hub: &Hub, skipped: &[&str]) -> Vec<(&'static str, Json)> {
    let mut keys: Vec<&'static str> = hal_c2_shell::controllers::registrations()
        .iter()
        .flat_map(|r| r.state_keys.iter().copied())
        .filter(|k| !skipped.contains(k))
        .collect();
    keys.sort_unstable();
    keys.into_iter()
        .map(|k| (k, unmade(hub.published(k))))
        .collect()
}

/// The shapes followed, as text, in order.
fn shapes(hub: &Hub) -> Vec<String> {
    let mut shapes: Vec<String> = hub
        .mc
        .subscriptions()
        .into_iter()
        .map(|(_, shape)| shape.to_string())
        .collect();
    shapes.sort();
    shapes
}

/// The keys of `started` and `opened` that differ, with both values.
fn differing(started: &Hub, opened: &Hub, skipped: &[&str]) -> Vec<String> {
    published(started, skipped)
        .into_iter()
        .zip(published(opened, skipped))
        .filter(|((_, started), (_, opened))| started != opened)
        .map(|((key, started), (_, opened))| format!("{key}: {started} != {opened}"))
        .collect()
}

#[test]
fn every_controller_follows_a_store_made_after_it_activated() {
    let (started, _kept) = clustered();
    cluster(&started);
    let (opened, _kept) = late();
    open(&opened);
    cluster(&opened);

    assert!(hal_c2_shell::has_mc(&opened.engine));
    assert_eq!(shapes(&opened), shapes(&started));
    let closed: Vec<&str> = PAGES.iter().map(|(key, ..)| *key).collect();
    // The wizard stays where it was for the shell it paired; the app shows
    // for the one that started with projects.
    let mut skipped = closed.clone();
    skipped.push("onboarding");
    assert_eq!(differing(&started, &opened, &skipped), Vec::<String>::new());
    // A page asks for what it shows as it opens.
    for (key, action, payload) in PAGES {
        for hub in [&started, &opened] {
            hub.dispatch(action, serde_json::from_str(payload).unwrap());
            hub.advance(0);
        }
        let others: Vec<&str> = hal_c2_shell::controllers::registrations()
            .iter()
            .flat_map(|r| r.state_keys.iter().copied())
            .filter(|k| *k != key)
            .collect();
        assert_eq!(differing(&started, &opened, &others), Vec::<String>::new());
    }
}

#[test]
fn a_thread_opened_after_the_store_is_made_is_followed_as_one_of_a_shell_with_an_mc() {
    let (started, _kept) = clustered();
    cluster(&started);
    let (opened, _kept) = late();
    open(&opened);
    cluster(&opened);
    for hub in [&started, &opened] {
        hub.dispatch("thread.open", json!({"key": "env-1:t1"}));
        hub.advance(0);
    }
    assert_eq!(threads::active(&opened.engine), "env-1:t1");
    assert_eq!(shapes(&opened), shapes(&started));
    assert!(
        shapes(&opened).iter().any(|shape| shape.contains("\"t1\"")),
        "the thread is followed"
    );
    let mut skipped = vec!["onboarding"];
    skipped.extend(PAGES.iter().map(|(key, ..)| *key));
    assert_eq!(differing(&started, &opened, &skipped), Vec::<String>::new());
}

#[test]
fn the_cache_of_a_store_made_later_wakes_the_loop_for_a_thread_it_loaded() {
    let (hub, _kept) = late();
    // The window gives the wake before the shell has an MC to make a cache.
    let woken = Arc::new(AtomicUsize::new(0));
    let wake = woken.clone();
    threads::set_wake(&hub.engine, move || {
        wake.fetch_add(1, Ordering::SeqCst);
    });
    open(&hub);
    let cache = store::cache(&hub.engine).expect("the cache");
    cache.load_thread("env-1:t1", |_| {});
    cache.drain();
    assert!(woken.load(Ordering::SeqCst) > 0);
}

#[derive(Clone, Copy, Debug)]
enum Step {
    /// The window gives the threads' cache its wake.
    Wake,
    /// The shell is opened at an MC (again, when it was).
    Open,
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 24, ..ProptestConfig::default() })]

    /// Whether the wake comes before the store or after it, and however
    /// often the shell is opened, the cache wakes the last one given.
    #[test]
    fn the_cache_wakes_the_last_wake_given_in_any_order(
        steps in proptest::collection::vec(
            prop_oneof![Just(Step::Wake), Just(Step::Open)],
            1..8,
        )
    ) {
        let (hub, _kept) = late();
        let counters: Vec<Arc<AtomicUsize>> = steps
            .iter()
            .map(|_| Arc::new(AtomicUsize::new(0)))
            .collect();
        let mut last = None;
        for (i, step) in steps.iter().enumerate() {
            match step {
                Step::Wake => {
                    let counter = counters[i].clone();
                    threads::set_wake(&hub.engine, move || {
                        counter.fetch_add(1, Ordering::SeqCst);
                    });
                    last = Some(i);
                }
                Step::Open => open(&hub),
            }
        }
        if let Some(cache) = store::cache(&hub.engine) {
            cache.load_thread("env-1:t1", |_| {});
            cache.drain();
        }
        for (i, counter) in counters.iter().enumerate() {
            let woke = counter.load(Ordering::SeqCst) > 0;
            let expected = last == Some(i) && hal_c2_shell::has_mc(&hub.engine);
            prop_assert_eq!(woke, expected, "wake {}", i);
        }
    }
}
