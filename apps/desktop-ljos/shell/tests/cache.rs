//! The client's cache (src/cache.rs, desktop-qt's tst_LocalCache): what it
//! keeps of a thread and of the thread list, the bounds on it, and starting
//! over when the file is of no use.

use std::cell::RefCell;
use std::path::Path;
use std::rc::Rc;

use hal_c2_shell::cache::{
    self, Cursor, Entity, LocalCache, ShellMcUpdate, ShellRow, Thread, ThreadUpdate,
};
use serde_json::{Map, Value, json};

fn fields(value: Value) -> Map<String, Value> {
    value.as_object().cloned().unwrap_or_default()
}

fn item(id: &str, run: i64, text: &str) -> Entity {
    Entity {
        kind: "turn-item".into(),
        id: id.into(),
        fields: fields(json!({"id": id, "text": text})),
        run: Some(run),
    }
}

fn run(ordinal: i64) -> Entity {
    let id = format!("run-{ordinal}");
    Entity {
        kind: "run".into(),
        fields: fields(json!({"id": id, "ordinal": ordinal})),
        id,
        run: None,
    }
}

fn cursor(handle: &str, offset: i64, floor: Option<i64>) -> Cursor {
    Cursor {
        handle: handle.into(),
        offset,
        floor,
    }
}

/// A whole copy of one run of two items, as a snapshot leaves it.
fn copy(key: &str, offset: i64) -> ThreadUpdate {
    ThreadUpdate {
        key: key.into(),
        cursor: cursor("log-1", offset, None),
        replace: true,
        put: vec![run(1), item("a", 1, "one"), item("b", 1, "")],
        gone: vec![],
    }
}

fn change(key: &str, offset: i64, put: Vec<Entity>) -> ThreadUpdate {
    ThreadUpdate {
        key: key.into(),
        cursor: cursor("log-1", offset, None),
        replace: false,
        put,
        gone: vec![],
    }
}

fn ids(thread: &Thread) -> Vec<String> {
    let mut found: Vec<String> = thread.entities.iter().map(|e| e.id.clone()).collect();
    found.sort();
    found
}

fn load(cache: &LocalCache, key: &str) -> Thread {
    let found = Rc::new(RefCell::new(None));
    let slot = found.clone();
    cache.load_thread(key, move |thread| *slot.borrow_mut() = Some(thread));
    cache.drain();
    found.borrow_mut().take().expect("drain runs the reply")
}

fn kept_shell(cache: &LocalCache, origin: &str) -> cache::Shell {
    let read = Rc::new(RefCell::new(None));
    let slot = read.clone();
    cache.shell(origin, move |shell| *slot.borrow_mut() = Some(shell));
    cache.drain();
    read.borrow_mut().take().expect("drain runs the reply")
}

fn clear(cache: &LocalCache) -> bool {
    let cleared = Rc::new(RefCell::new(None));
    let slot = cleared.clone();
    cache.clear(move |done| *slot.borrow_mut() = Some(done));
    cache.drain();
    cleared.borrow_mut().take().expect("drain runs the reply")
}

fn open(dir: &Path) -> LocalCache {
    LocalCache::open(Some(dir))
}

/// Runs statements on the cache's file from outside it, as a disk that
/// starts refusing writes would change what it accepts.
fn tamper(dir: &Path, statements: &[&str]) {
    let db = rusqlite::Connection::open(dir.join(cache::FILE)).unwrap();
    for statement in statements {
        db.execute_batch(statement).unwrap();
    }
}

/// Whether any file of the cache still holds `text`.
fn on_disk(dir: &Path, text: &[u8]) -> bool {
    std::fs::read_dir(dir).unwrap().flatten().any(|entry| {
        std::fs::read(entry.path())
            .map(|bytes| bytes.windows(text.len()).any(|w| w == text))
            .unwrap_or(false)
    })
}

#[test]
fn a_thread_is_kept_as_of_its_cursor() {
    let dir = tempfile::tempdir().unwrap();
    let key = "env-a:thread-1";
    {
        let cache = open(dir.path());
        assert!(cache.is_open());
        assert!(!load(&cache, key).found());
        cache.store_thread(copy(key, 10));
        // A change lands with the cursor that says what it reflects.
        cache.store_thread(ThreadUpdate {
            key: key.into(),
            cursor: cursor("log-1", 12, Some(4)),
            replace: false,
            put: vec![item("a", 1, "two"), item("c", 1, "")],
            gone: vec![("turn-item".into(), "b".into())],
        });
    }
    // Another run of the app reads what the last one kept.
    let cache = open(dir.path());
    let thread = load(&cache, key);
    assert!(thread.found());
    assert_eq!(thread.cursor, cursor("log-1", 12, Some(4)));
    assert_eq!(ids(&thread), ["a", "c", "run-1"]);
    for entity in &thread.entities {
        if entity.id == "a" {
            assert_eq!(entity.fields["text"], "two");
            assert_eq!(entity.run, Some(1));
        }
        if entity.id == "run-1" {
            assert_eq!(entity.run, None);
        }
    }
}

#[test]
fn a_snapshot_replaces_the_copy() {
    let dir = tempfile::tempdir().unwrap();
    let key = "env-a:thread-1";
    let cache = open(dir.path());
    cache.store_thread(copy(key, 10));
    cache.store_thread(ThreadUpdate {
        key: key.into(),
        cursor: cursor("log-2", 3, None),
        replace: true,
        put: vec![item("z", 1, "")],
        gone: vec![],
    });
    let thread = load(&cache, key);
    assert_eq!(thread.cursor.handle, "log-2");
    assert_eq!(ids(&thread), ["z"]);
}

#[test]
fn a_change_to_a_forgotten_thread_is_left_alone() {
    let dir = tempfile::tempdir().unwrap();
    let key = "env-a:thread-1";
    let cache = open(dir.path());
    cache.store_thread(copy(key, 10));
    cache.forget_thread(key);
    // Half a copy would pass for a whole one at its cursor.
    cache.store_thread(change(key, 14, vec![item("c", 1, "")]));
    assert!(!load(&cache, key).found());
}

#[test]
fn a_closed_thread_is_trimmed_to_its_newest_runs() {
    let dir = tempfile::tempdir().unwrap();
    let key = "env-a:thread-1";
    let cache = open(dir.path());
    let mut whole = ThreadUpdate {
        key: key.into(),
        cursor: cursor("log-1", 10, None),
        replace: true,
        ..Default::default()
    };
    for ordinal in 1..=6 {
        whole.put.push(run(ordinal));
        whole
            .put
            .push(item(&format!("item-{ordinal}"), ordinal, ""));
    }
    // One of no run, which no window leaves out.
    whole.put.push(Entity {
        kind: "turn-item".into(),
        id: "loose".into(),
        ..Default::default()
    });
    cache.store_thread(whole);
    cache.trim_thread(key, 5);
    let thread = load(&cache, key);
    assert_eq!(thread.cursor.floor, Some(5));
    assert_eq!(thread.cursor.offset, 10);
    // The runs themselves are held whole; their items from the floor on.
    assert_eq!(thread.entities.len(), 6 + 2 + 1);
    let found = ids(&thread);
    assert!(found.contains(&"item-5".into()) && found.contains(&"loose".into()));
    assert!(!found.contains(&"item-4".into()));
    // A window that already starts later is not widened by a trim.
    cache.trim_thread(key, 3);
    let thread = load(&cache, key);
    assert_eq!(thread.cursor.floor, Some(5));
    assert_eq!(thread.entities.len(), 6 + 2 + 1);
}

#[test]
fn the_most_recently_opened_threads_are_kept() {
    let dir = tempfile::tempdir().unwrap();
    let cache = open(dir.path());
    let key = |n: i64| format!("env-a:thread-{n}");
    for n in 0..cache::THREADS {
        cache.store_thread(copy(&key(n), 10));
    }
    // Opening the oldest makes it the most recent.
    assert!(load(&cache, &key(0)).found());
    cache.store_thread(copy(&key(cache::THREADS), 10));
    assert!(load(&cache, &key(0)).found());
    assert!(load(&cache, &key(cache::THREADS)).found());
    // The one opened longest ago made room, with everything it held.
    let evicted = load(&cache, &key(1));
    assert!(!evicted.found());
    assert!(evicted.entities.is_empty());
    assert!(load(&cache, &key(2)).found());
}

#[test]
fn an_environment_is_forgotten_with_its_threads() {
    let dir = tempfile::tempdir().unwrap();
    let cache = open(dir.path());
    cache.store_thread(copy("env-a:thread-1", 10));
    cache.store_thread(copy("env-a:thread-2", 10));
    cache.store_thread(copy("env-ab:thread-1", 10));
    cache.forget_environment("env-a");
    assert!(!load(&cache, "env-a:thread-1").found());
    assert!(!load(&cache, "env-a:thread-2").found());
    assert!(load(&cache, "env-ab:thread-1").found());
}

// Leaving the MC for good: nothing kept stays, in the file or its journal.
#[test]
fn clearing_leaves_nothing_on_disk() {
    let dir = tempfile::tempdir().unwrap();
    let cache = open(dir.path());
    cache.store_thread(copy("env-a:thread-kept", 10));
    cache.drain();
    assert!(on_disk(dir.path(), b"thread-kept"));
    assert!(clear(&cache));
    assert!(!load(&cache, "env-a:thread-kept").found());
    assert!(!on_disk(dir.path(), b"thread-kept"));
}

#[cfg(unix)]
fn chmod(path: &Path, mode: u32) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).unwrap();
}

// A file that cannot be removed is emptied where it is, not opened again as it was.
#[cfg(unix)]
#[test]
fn a_cache_that_cannot_be_removed_is_emptied() {
    let dir = tempfile::tempdir().unwrap();
    let cache = open(dir.path());
    cache.store_thread(copy("env-a:thread-kept", 10));
    cache.drain();
    chmod(dir.path(), 0o500);
    let cleared = clear(&cache);
    let found = load(&cache, "env-a:thread-kept").found();
    chmod(dir.path(), 0o700);
    assert!(cleared);
    assert!(!found);
    assert!(!on_disk(dir.path(), b"thread-kept"));
    // Nor is it there for the next run.
    drop(cache);
    assert!(!load(&open(dir.path()), "env-a:thread-kept").found());
}

// One that can be neither removed nor written says so, and is not read.
#[cfg(unix)]
#[test]
fn a_cache_that_cannot_be_emptied_is_not_read() {
    let dir = tempfile::tempdir().unwrap();
    let cache = open(dir.path());
    cache.store_thread(copy("env-a:thread-kept", 10));
    cache.drain();
    let files: Vec<_> = std::fs::read_dir(dir.path())
        .unwrap()
        .flatten()
        .map(|e| e.path())
        .collect();
    for file in &files {
        chmod(file, 0o400);
    }
    chmod(dir.path(), 0o500);
    let cleared = clear(&cache);
    let found = load(&cache, "env-a:thread-kept").found();
    chmod(dir.path(), 0o700);
    for file in &files {
        chmod(file, 0o600);
    }
    assert!(!cleared);
    assert!(!found);
}

fn row(id: &str, title: &str) -> ShellRow {
    ShellRow {
        id: id.into(),
        kind: "thread".into(),
        fields: fields(json!({"id": id, "title": title})),
    }
}

fn env_a() -> Map<String, Value> {
    fields(json!({"environmentId": "env-a"}))
}

#[test]
fn the_thread_list_is_kept_by_origin_with_its_versions() {
    let dir = tempfile::tempdir().unwrap();
    let origin = "http://127.0.0.1:3780";
    {
        let cache = open(dir.path());
        assert!(kept_shell(&cache, origin).mcs.is_empty());
        assert!(kept_shell(&cache, "").origin.is_empty());
        cache.store_shell(
            origin,
            vec![
                ShellMcUpdate {
                    mc: "mc-a".into(),
                    reset: true,
                    epoch: "epoch-1".into(),
                    rev: 2,
                    environment: env_a(),
                    put: vec![row("t1", "One"), row("t2", "Two")],
                    ..Default::default()
                },
                ShellMcUpdate {
                    mc: "mc-b".into(),
                    reset: true,
                    put: vec![row("t9", "Nine")],
                    ..Default::default()
                },
            ],
        );
        // The rows changed since, and the version they bring it to.
        cache.store_shell(
            origin,
            vec![
                ShellMcUpdate {
                    mc: "mc-a".into(),
                    epoch: "epoch-1".into(),
                    rev: 4,
                    environment: env_a(),
                    put: vec![row("t2", "Two again"), row("t3", "Three")],
                    gone: vec!["t1".into()],
                    ..Default::default()
                },
                ShellMcUpdate {
                    mc: "mc-b".into(),
                    removed: true,
                    ..Default::default()
                },
            ],
        );
        // A change for an MC whose rows are not kept is not its rows.
        cache.store_shell(
            origin,
            vec![ShellMcUpdate {
                mc: "mc-c".into(),
                rev: 9,
                put: vec![row("t8", "Eight")],
                ..Default::default()
            }],
        );
    }
    let cache = open(dir.path());
    // Before the client knows its MC, the one it was last opened at.
    assert_eq!(kept_shell(&cache, "").origin, origin);
    let shell = kept_shell(&cache, origin).mcs;
    assert_eq!(shell.len(), 1);
    assert_eq!(shell[0].mc, "mc-a");
    assert_eq!(shell[0].epoch, "epoch-1");
    assert_eq!(shell[0].rev, 4);
    assert_eq!(shell[0].environment["environmentId"], "env-a");
    let mut titles: Vec<_> = shell[0]
        .rows
        .iter()
        .map(|r| r.fields["title"].as_str().unwrap().to_owned())
        .collect();
    titles.sort();
    assert_eq!(titles, ["Three", "Two again"]);
    // A reset replaces the MC's rows.
    cache.store_shell(
        origin,
        vec![ShellMcUpdate {
            mc: "mc-a".into(),
            reset: true,
            epoch: "epoch-2".into(),
            rev: 1,
            put: vec![row("t7", "Seven")],
            ..Default::default()
        }],
    );
    let shell = kept_shell(&cache, origin).mcs;
    assert_eq!(shell[0].rows.len(), 1);
    assert_eq!(shell[0].epoch, "epoch-2");
    // Opened at another MC, the client holds nothing of this one any more.
    assert!(kept_shell(&cache, "http://127.0.0.1:3781").mcs.is_empty());
    assert!(kept_shell(&cache, origin).mcs.is_empty());
    assert!(kept_shell(&cache, "").origin.is_empty());
}

// A change that cannot be written leaves a copy that no longer matches its
// cursor. It is dropped; one that cannot even be dropped is never read, and
// never changed, until it can be.
#[test]
fn a_copy_that_missed_a_change_is_never_read() {
    let dir = tempfile::tempdir().unwrap();
    let key = "env-a:thread-1";
    let cache = open(dir.path());
    cache.store_thread(copy(key, 10));
    assert!(load(&cache, key).found());

    // The disk refuses one row, and refuses to give the cursor up.
    tamper(
        dir.path(),
        &[
            "CREATE TRIGGER refuse_put BEFORE INSERT ON entities WHEN NEW.id = 'c' BEGIN SELECT RAISE(ABORT, 'refused'); END",
            "CREATE TRIGGER refuse_drop BEFORE DELETE ON threads BEGIN SELECT RAISE(ABORT, 'refused'); END",
        ],
    );
    cache.store_thread(change(key, 11, vec![item("c", 1, "")]));
    // Its cursor still says 10 and its rows are whole as of 10, but what
    // follows was built on 11: it is not handed out.
    assert!(!load(&cache, key).found());

    // Nor brought forward by a later change while it cannot be dropped.
    cache.store_thread(change(key, 12, vec![item("d", 1, "")]));
    assert!(!load(&cache, key).found());

    // Once it can be dropped it is, and a snapshot makes a copy again.
    tamper(dir.path(), &["DROP TRIGGER refuse_drop"]);
    cache.store_thread(change(key, 13, vec![item("e", 1, "")]));
    assert!(!load(&cache, key).found());
    cache.store_thread(copy(key, 14));
    let again = load(&cache, key);
    assert_eq!(again.cursor.offset, 14);
    assert_eq!(ids(&again), ["a", "b", "run-1"]);
}

// The thread list goes the same way: one that missed a change is not read,
// and the rows that changed afterwards do not pass for all of an MC's rows.
#[test]
fn a_thread_list_that_missed_a_change_is_never_read() {
    let dir = tempfile::tempdir().unwrap();
    let origin = "http://127.0.0.1:3780";
    let change = |reset: bool, rev: i64, id: &str| {
        vec![ShellMcUpdate {
            mc: "mc-a".into(),
            reset,
            epoch: "epoch-1".into(),
            rev,
            environment: env_a(),
            put: vec![ShellRow {
                id: id.into(),
                kind: "thread".into(),
                fields: fields(json!({"id": id})),
            }],
            ..Default::default()
        }]
    };
    let cache = open(dir.path());
    cache.store_shell(origin, change(true, 2, "t1"));
    assert_eq!(kept_shell(&cache, origin).mcs.len(), 1);

    tamper(
        dir.path(),
        &[
            "CREATE TRIGGER refuse_put BEFORE INSERT ON shell_rows WHEN NEW.id = 'bad' BEGIN SELECT RAISE(ABORT, 'refused'); END",
            "CREATE TRIGGER refuse_drop BEFORE DELETE ON shell_mcs BEGIN SELECT RAISE(ABORT, 'refused'); END",
        ],
    );
    cache.store_shell(origin, change(false, 3, "bad"));
    // Its version still says 2 and its rows are whole as of 2, but the MC
    // was told the client holds 3.
    assert!(kept_shell(&cache, origin).mcs.is_empty());
    cache.store_shell(origin, change(false, 4, "t4"));
    assert!(kept_shell(&cache, origin).mcs.is_empty());

    // Once it can be dropped it is. One changed row is not the MC's rows.
    tamper(dir.path(), &["DROP TRIGGER refuse_drop"]);
    cache.store_shell(origin, change(false, 5, "t5"));
    assert!(kept_shell(&cache, origin).mcs.is_empty());
    // All of its rows are.
    cache.store_shell(origin, change(true, 6, "t6"));
    let shell = kept_shell(&cache, origin).mcs;
    assert_eq!(shell.len(), 1);
    assert_eq!(shell[0].rev, 6);
    assert_eq!(shell[0].rows.len(), 1);
}

#[test]
fn another_schema_starts_over() {
    let dir = tempfile::tempdir().unwrap();
    let key = "env-a:thread-1";
    open(dir.path()).store_thread(copy(key, 10));
    tamper(
        dir.path(),
        &[
            &format!(
                "UPDATE meta SET value = '{}' WHERE key = 'schema'",
                cache::SCHEMA + 1
            ),
            // A table this version knows nothing of goes too.
            "CREATE TABLE later(id TEXT)",
        ],
    );
    let cache = open(dir.path());
    assert!(cache.is_open());
    assert!(!load(&cache, key).found());
    cache.store_thread(copy(key, 10));
    assert!(load(&cache, key).found());
}

#[test]
fn a_file_that_is_no_database_starts_over() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join(cache::FILE), vec![b'x'; 4096]).unwrap();
    let cache = open(dir.path());
    assert!(cache.is_open());
    cache.store_thread(copy("env-a:thread-1", 10));
    assert!(load(&cache, "env-a:thread-1").found());
}

#[test]
fn without_a_directory_nothing_is_kept() {
    let cache = LocalCache::open(None);
    assert!(!cache.is_open());
    cache.store_thread(copy("env-a:thread-1", 10));
    let answered = Rc::new(RefCell::new(false));
    let seen = answered.clone();
    cache.load_thread("env-a:thread-1", move |thread| {
        *seen.borrow_mut() = !thread.found()
    });
    // Never from inside the call, with or without a database.
    assert!(!*answered.borrow());
    cache.drain();
    assert!(*answered.borrow());
    assert!(kept_shell(&cache, "http://127.0.0.1:3780").mcs.is_empty());
}

#[test]
fn a_reply_wakes_its_owner() {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    let dir = tempfile::tempdir().unwrap();
    let cache = open(dir.path());
    let woken = Arc::new(AtomicUsize::new(0));
    let count = woken.clone();
    cache.set_wake(move || {
        count.fetch_add(1, Ordering::SeqCst);
    });
    cache.load_thread("env-a:thread-1", |_| {});
    cache.drain();
    assert_eq!(woken.load(Ordering::SeqCst), 1);
}
