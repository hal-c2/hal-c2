//! The fold, frame by frame, as desktop-qt's ShellStore applies them.

use super::*;

const ORIGIN: &str = "http://127.0.0.1:3773";
const AT: &str = "2026-09-23T09:00:00Z";

fn frame(value: Value) -> Frame {
    value.as_object().cloned().unwrap()
}

fn env(id: &str) -> Value {
    json!({"environmentId": id, "label": id, "capabilities": {"threadSnooze": true, "pullRequests": true}})
}

fn thread(id: &str) -> Value {
    json!({"id": id, "projectId": "p1", "title": id, "createdAt": AT, "updatedAt": AT})
}

fn project(id: &str, created: &str) -> Value {
    json!({"id": id, "title": id, "workspaceRoot": format!("/w/{id}"), "createdAt": created, "updatedAt": created})
}

/// A whole cluster: `mc-a` serving env-a with p1 and t1, t2.
fn snapshot() -> Frame {
    frame(json!({
        "t": "shell",
        "mcs": [{"mc": "mc-a", "environment": env("env-a"), "online": true, "epoch": "e1", "rev": 4}],
        "rows": [
            ["mc-a", "p1", "project", project("p1", AT)],
            ["mc-a", "t1", "thread", thread("t1")],
            ["mc-a", "t2", "thread", thread("t2")],
        ],
    }))
}

fn keys(store: &ShellStore) -> Vec<String> {
    let mut keys: Vec<String> = store.threads().iter().map(|t| t.key()).collect();
    keys.sort();
    keys
}

#[test]
fn a_snapshot_is_the_cluster() {
    let mut store = ShellStore::default();
    assert!(!store.synchronized());
    assert!(store.apply(&snapshot()));
    assert!(store.synchronized() && !store.previewing());
    assert_eq!(store.snapshots(), 1);
    assert_eq!(keys(&store), ["env-a:t1", "env-a:t2"]);
    assert_eq!(store.projects()[0].key(), "env-a:p1");
    assert_eq!(store.environments(), ["env-a"]);
    assert_eq!(store.mc_serving("env-a"), "mc-a");
    assert_eq!(store.environment_of("mc-a"), "env-a");
    assert!(store.capabilities("env-a").snooze);
    assert!(store.supports("env-a", "pullRequests"));
    assert!(store.thread_online("env-a:t1"));
    assert_eq!(store.have(), json!({"mc-a": ["e1", 4]}));
    assert!(!store.apply(&frame(json!({"t": "unknown"}))));
}

#[test]
fn row_changes_put_delete_and_reset() {
    let mut store = ShellStore::default();
    store.apply(&snapshot());
    store.apply(&frame(json!({
        "t": "shell.rows", "mc": "mc-a", "epoch": "e1", "rev": 5,
        "rows": [["t3", "thread", thread("t3")], ["t1", "thread", {"id": "t1", "deletedAt": AT}], ["x", "other", {}]],
    })));
    assert_eq!(keys(&store), ["env-a:t2", "env-a:t3"]);
    assert_eq!(store.have(), json!({"mc-a": ["e1", 5]}));
    store.apply(&frame(json!({
        "t": "shell.rows", "mc": "mc-a", "reset": true,
        "rows": [["t9", "thread", thread("t9")]],
    })));
    assert_eq!(keys(&store), ["env-a:t9"]);
    assert!(store.projects().is_empty());
    // No version given: none to resume from.
    assert_eq!(store.have(), json!({}));
}

#[test]
fn an_offline_mc_keeps_its_rows_and_a_removed_one_takes_them() {
    let mut store = ShellStore::default();
    store.apply(&snapshot());
    store.apply(&frame(
        json!({"t": "shell.mc", "mc": "mc-a", "online": false}),
    ));
    assert_eq!(keys(&store).len(), 2);
    assert!(!store.environment_online("env-a"));
    store.apply(&frame(
        json!({"t": "shell.mc", "mc": "mc-a", "removed": true}),
    ));
    assert!(keys(&store).is_empty());
    assert!(!store.serves_environment("env-a"));
}

#[test]
fn a_moved_thread_is_listed_where_it_lives() {
    let mut store = ShellStore::default();
    let moving = json!({"id": "t1", "projectId": "p1", "title": "t1", "createdAt": AT, "updatedAt": AT,
                        "moving": {"environmentId": "env-b", "label": "Laptop"}});
    store.apply(&frame(json!({
        "t": "shell",
        "mcs": [
            {"mc": "mc-a", "environment": env("env-a"), "online": true},
            {"mc": "mc-b", "environment": env("env-b"), "online": true},
        ],
        "rows": [["mc-a", "t1", "thread", moving]],
    })));
    // On its way: still where it was, saying where it goes.
    assert_eq!(keys(&store), ["env-a:t1"]);
    assert_eq!(
        store.thread("env-a:t1").unwrap().moving_to.as_deref(),
        Some("Laptop")
    );

    // Arrived: the old machine's copy steps aside, then becomes a record.
    store.apply(&frame(
        json!({"t": "shell.rows", "mc": "mc-b", "rows": [["t1", "thread", thread("t1")]]}),
    ));
    assert_eq!(keys(&store), ["env-b:t1"]);
    assert_eq!(store.located("env-a:t1"), "env-b:t1");
    store.apply(&frame(json!({"t": "shell.rows", "mc": "mc-a",
        "rows": [["t1", "thread", {"id": "t1", "movedTo": {"environmentId": "env-b"}}]]})));
    assert_eq!(keys(&store), ["env-b:t1"]);
    assert!(store.thread("env-a:t1").is_none());
    assert!(store.thread_row("env-a:t1").is_some());

    // The new machine's rows are not in yet: the record points the way.
    store.apply(&frame(
        json!({"t": "shell.rows", "mc": "mc-b", "reset": true, "rows": []}),
    ));
    assert_eq!(store.located("env-a:t1"), "env-b:t1");
    assert_eq!(store.located("env-a:nothing"), "env-a:nothing");
}

#[test]
fn projects_list_by_creation() {
    let mut store = ShellStore::default();
    store.apply(&frame(json!({
        "t": "shell",
        "mcs": [{"mc": "mc-a", "environment": env("env-a")}],
        "rows": [
            ["mc-a", "late", "project", project("late", "2026-09-02T00:00:00Z")],
            ["mc-a", "early", "project", project("early", "2026-09-01T00:00:00Z")],
        ],
    })));
    let ids: Vec<String> = store.projects().into_iter().map(|p| p.id).collect();
    assert_eq!(ids, ["early", "late"]);
    assert!(store.project("env-a:late").is_some());
    assert!(store.project("late").is_none());
    assert_eq!(store.project_rows("env-a").len(), 2);
}

#[test]
fn a_refused_subscription_says_why_until_a_snapshot() {
    let mut store = ShellStore::default();
    store.apply(&frame(json!({"t": "error"})));
    assert_eq!(
        store.problem(),
        "The MC did not send its projects and threads."
    );
    store.apply(&frame(json!({"t": "error", "reason": "No."})));
    assert_eq!(store.problem(), "No.");
    store.apply(&snapshot());
    assert_eq!(store.problem(), "");
}

#[test]
fn an_environment_change_is_its_new_descriptor() {
    let mut store = ShellStore::default();
    store.apply(&snapshot());
    store.apply(&frame(json!({"t": "shell.environment", "mc": "mc-a",
        "environment": {"environmentId": "env-a", "capabilities": {"threadSettlement": true}}})));
    let caps = store.capabilities("env-a");
    assert!(caps.settlement && !caps.snooze);
}

fn cached(dir: &std::path::Path) -> ShellStore {
    ShellStore::new(Some(Rc::new(LocalCache::open(Some(dir)))))
}

/// What the cache answered the store's last read with, held as the shell's
/// loop does once it is woken.
fn kept(store: &mut ShellStore) -> Changes {
    store.cache().cloned().unwrap().drain();
    store.take_kept()
}

#[test]
fn kept_rows_preview_until_the_mc_answers_and_resume_from_their_version() {
    let dir = tempfile::tempdir().unwrap();
    {
        let mut store = cached(dir.path());
        store.open(ORIGIN);
        store.apply(&snapshot());
        store.apply(&frame(
            json!({"t": "shell.rows", "mc": "mc-a", "epoch": "e1", "rev": 6,
            "rows": [["t3", "thread", thread("t3")]]}),
        ));
        // Dropped with a change unflushed: it is written then.
    }
    let mut store = cached(dir.path());
    // Nothing waits on the cache: its rows come in later.
    assert_eq!(
        store.open(&format!("{ORIGIN}/some/path?q=1")),
        Changes::default()
    );
    assert!(keys(&store).is_empty());
    assert_eq!(kept(&mut store), Changes::changed(true));
    assert!(store.previewing() && !store.synchronized());
    assert_eq!(keys(&store), ["env-a:t1", "env-a:t2", "env-a:t3"]);
    assert_eq!(store.have(), json!({"mc-a": ["e1", 6]}));
    assert!(!store.flush_due(), "what was read is owed to no one");

    // The MC sends only what changed since.
    store.apply(&frame(json!({
        "t": "shell",
        "mcs": [{"mc": "mc-a", "environment": env("env-a"), "online": true, "reset": false, "epoch": "e1", "rev": 7}],
        "rows": [["mc-a", "t2", "thread", {"id": "t2", "deletedAt": AT}]],
    })));
    assert!(store.synchronized() && !store.previewing());
    assert_eq!(keys(&store), ["env-a:t1", "env-a:t3"]);

    // Kept the same way: what the next start sees.
    drop(store);
    let mut store = cached(dir.path());
    store.show_kept();
    assert!(kept(&mut store).changed);
    assert_eq!(store.origin(), ORIGIN);
    assert_eq!(keys(&store), ["env-a:t1", "env-a:t3"]);
}

#[test]
fn another_origin_shows_nothing_of_the_first() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = cached(dir.path());
    store.open(ORIGIN);
    store.apply(&snapshot());
    assert_eq!(store.open(ORIGIN), Changes::default());
    let other = store.open("http://10.0.0.2:3773");
    assert_eq!(
        other,
        Changes {
            changed: true,
            origin_changed: true
        }
    );
    assert!(keys(&store).is_empty());
    assert!(!store.previewing());
    // show_kept is only for a store that has no origin yet.
    store.show_kept();
    assert_eq!(kept(&mut store), Changes::default());
}

#[test]
fn kept_rows_for_where_the_store_no_longer_is_are_not_held() {
    let dir = tempfile::tempdir().unwrap();
    {
        let mut store = cached(dir.path());
        store.open(ORIGIN);
        store.apply(&snapshot());
    }
    // Opened elsewhere before the first answer came in.
    let mut store = cached(dir.path());
    store.open(ORIGIN);
    store.open("http://10.0.0.2:3773");
    assert_eq!(kept(&mut store), Changes::default());
    assert!(keys(&store).is_empty() && !store.previewing());
    // Its MC answered first.
    let mut store = cached(dir.path());
    store.open(ORIGIN);
    store.apply(&frame(json!({"t": "shell", "mcs": [], "rows": []})));
    assert_eq!(kept(&mut store), Changes::default());
    assert!(keys(&store).is_empty() && store.synchronized());
}

#[test]
fn an_mc_that_leaves_takes_its_cached_threads() {
    let dir = tempfile::tempdir().unwrap();
    let cache = Rc::new(LocalCache::open(Some(dir.path())));
    let mut store = ShellStore::new(Some(cache.clone()));
    store.open(ORIGIN);
    store.apply(&snapshot());
    cache.store_thread(cache::ThreadUpdate {
        key: "env-a:t1".into(),
        cursor: cache::Cursor {
            handle: "h".into(),
            offset: 1,
            floor: None,
        },
        replace: true,
        ..cache::ThreadUpdate::default()
    });
    let found = |key: &str| {
        let slot = Rc::new(Cell::new(false));
        let seen = slot.clone();
        cache.load_thread(key, move |t| seen.set(t.found()));
        cache.drain();
        slot.get()
    };
    assert!(found("env-a:t1"));
    store.apply(&frame(json!({"t": "shell", "mcs": [], "rows": []})));
    assert!(!found("env-a:t1"));
    assert!(store.environments().is_empty());
}

#[test]
fn clearing_lets_go_of_everything() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = cached(dir.path());
    store.open(ORIGIN);
    store.apply(&snapshot());
    let cleared = Rc::new(Cell::new(false));
    let done = cleared.clone();
    store.clear(move |ok| done.set(ok));
    kept(&mut store);
    assert!(cleared.get());
    assert!(store.synchronized() && keys(&store).is_empty());
    assert_eq!(store.origin(), "");
    drop(store);
    let mut store = cached(dir.path());
    store.open(ORIGIN);
    assert_eq!(kept(&mut store), Changes::default());
    assert!(!store.previewing());
}

#[test]
fn origins_are_keyed_without_path_or_credentials() {
    assert_eq!(
        origin_key("http://me:pw@host:3773/a?b#c"),
        "http://host:3773"
    );
    assert_eq!(origin_key("https://host"), "https://host");
    assert_eq!(origin_key("not a url"), "not a url");
}
