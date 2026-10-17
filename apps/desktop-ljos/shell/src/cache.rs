//! The client's cache, ported from desktop-qt's LocalCache: what it keeps of
//! its MC between connections and runs, so it paints before the socket is up
//! and is sent only what it lacks. One SQLite database in the cache
//! directory. Deleting it is harmless, and so is a schema it does not know,
//! which is started over.
//!
//! ```ignore
//! let cache = LocalCache::open(&paths.cache);
//! cache.shell("")                                   // the sidebar, at startup
//! cache.load_thread(key, move |thread| { ... });    // runs in deliver()
//! cache.store_thread(update);                       // queued; one transaction per batch
//! ```
//!
//! Every statement runs on one worker thread that owns the connection. The
//! calling thread only waits for it in `shell`, `clear` and `drain`. Work is
//! done in the order it was asked for, so a read sees the writes before it.
//! `load_thread` replies come back to the owner, who runs them with
//! [`LocalCache::deliver`] once the wake given to [`LocalCache::set_wake`]
//! says there are some.

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Map, Value};

/// Bumped when a table changes: an older or newer database is dropped.
pub const SCHEMA: i64 = 1;
/// The threads kept, most recently opened first.
pub const THREADS: i64 = 100;
/// The file in the cache directory.
pub const FILE: &str = "client-cache.sqlite";

/// One entity of a thread's stream, as the timeline holds it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Entity {
    pub kind: String,
    pub id: String,
    pub fields: Map<String, Value>,
    /// The ordinal of its run, for the kinds a window bounds (turn items and
    /// messages of a run); none for the rest, which are held whole.
    pub run: Option<i64>,
}

/// Where a copy of a thread stands: the MC log it follows (`handle`), the
/// offset it reflects, and the first run of its window (none: it reaches the
/// start of the thread). `offset` is negative when there is no copy.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Cursor {
    pub handle: String,
    pub offset: i64,
    pub floor: Option<i64>,
}

impl Default for Cursor {
    fn default() -> Self {
        Cursor {
            handle: String::new(),
            offset: -1,
            floor: None,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Thread {
    pub cursor: Cursor,
    pub entities: Vec<Entity>,
}

impl Thread {
    pub fn found(&self) -> bool {
        self.cursor.offset >= 0
    }
}

/// A change to a thread's copy, which lands whole: the entities and the
/// cursor that says what they reflect.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ThreadUpdate {
    /// `environmentId:threadId`.
    pub key: String,
    pub cursor: Cursor,
    /// After a snapshot: `put` is the whole copy. Otherwise a change to a
    /// copy that is there; one the cache no longer holds is left alone.
    pub replace: bool,
    pub put: Vec<Entity>,
    /// (kind, id)
    pub gone: Vec<(String, String)>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ShellRow {
    pub id: String,
    pub kind: String,
    pub fields: Map<String, Value>,
}

/// One MC of the sidebar: its environment, its rows, and the version the MC
/// gave them (`epoch` empty when it gave none).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ShellMc {
    pub mc: String,
    pub epoch: String,
    pub rev: i64,
    pub environment: Map<String, Value>,
    pub rows: Vec<ShellRow>,
}

/// The sidebar as kept, and the origin of the MC it is of (empty: none is kept).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Shell {
    pub origin: String,
    pub mcs: Vec<ShellMc>,
}

/// A change to one MC of the sidebar.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ShellMcUpdate {
    pub mc: String,
    /// The MC left the cluster: it and its rows go.
    pub removed: bool,
    /// Its rows are replaced by `put`.
    pub reset: bool,
    pub epoch: String,
    pub rev: i64,
    pub environment: Map<String, Value>,
    pub put: Vec<ShellRow>,
    /// Row ids.
    pub gone: Vec<String>,
}

type Job = Box<dyn FnOnce(&mut Worker) + Send>;
type Reply = Box<dyn FnOnce(Thread)>;
type Wake = Arc<dyn Fn() + Send + Sync>;

enum Msg {
    /// Batched with the jobs around it into one transaction.
    Job(Job),
    /// Run on its own, outside any transaction, after what came before.
    Control(Job),
    Quit,
}

struct Open {
    tx: Sender<Msg>,
    thread: Option<JoinHandle<()>>,
    replies: Receiver<(u64, Thread)>,
}

/// The cache. `!Send`: it lives on the thread that owns the UI.
pub struct LocalCache {
    open: Option<Open>,
    wake: Arc<Mutex<Option<Wake>>>,
    pending: RefCell<HashMap<u64, Reply>>,
    /// Replies for a cache that is not open, which still come later.
    unopened: RefCell<VecDeque<Reply>>,
    next: Cell<u64>,
}

impl Default for LocalCache {
    /// A cache that keeps nothing, as `open` without a directory.
    fn default() -> Self {
        LocalCache {
            open: None,
            wake: Arc::new(Mutex::new(None)),
            pending: RefCell::default(),
            unopened: RefCell::default(),
            next: Cell::new(0),
        }
    }
}

impl LocalCache {
    /// Opens `<dir>/client-cache.sqlite`, creating it. Without it (no
    /// directory, a file that cannot be written) nothing is kept and every
    /// read comes back empty.
    pub fn open(dir: Option<&Path>) -> LocalCache {
        let mut cache = LocalCache::default();
        let Some(dir) = dir.filter(|d| !d.as_os_str().is_empty()) else {
            return cache;
        };
        if std::fs::create_dir_all(dir).is_err() {
            return cache;
        }
        let path = dir.join(FILE);
        let (tx, rx) = mpsc::channel::<Msg>();
        let (reply_tx, replies) = mpsc::channel();
        let (opened_tx, opened_rx) = mpsc::channel();
        let wake = cache.wake.clone();
        let thread = std::thread::Builder::new()
            .name("hal-c2-cache".into())
            .spawn(move || {
                let mut worker = Worker {
                    db: None,
                    path,
                    lost: Lost::default(),
                    replies: reply_tx,
                    wake,
                };
                let opened = worker.open();
                let _ = opened_tx.send(opened);
                if opened {
                    worker.serve(rx);
                }
            });
        let Ok(thread) = thread else {
            return cache;
        };
        if opened_rx.recv().unwrap_or(false) {
            cache.open = Some(Open {
                tx,
                thread: Some(thread),
                replies,
            });
        } else {
            let _ = thread.join();
        }
        cache
    }

    pub fn is_open(&self) -> bool {
        self.open.is_some()
    }

    /// Called from the worker when a `load_thread` reply is ready, and from
    /// `load_thread` itself on a cache that is not open: the owner then runs
    /// [`LocalCache::deliver`] on its own thread. The shell's ThreadStore is
    /// the only reader: `controllers::threads::set_wake` hands it the event
    /// loop's wake.
    pub fn set_wake(&self, wake: impl Fn() + Send + Sync + 'static) {
        *self.wake.lock().unwrap_or_else(|e| e.into_inner()) = Some(Arc::new(wake));
    }

    fn wake(&self) {
        let wake = self.wake.lock().unwrap_or_else(|e| e.into_inner()).clone();
        if let Some(wake) = wake {
            wake();
        }
    }

    fn post(&self, job: impl FnOnce(&mut Worker) + Send + 'static) {
        if let Some(open) = &self.open {
            let _ = open.tx.send(Msg::Job(Box::new(job)));
        }
    }

    /// Runs `job` on the worker after what was asked for so far, outside any
    /// transaction, and waits for what it returns.
    fn control<T: Send + 'static>(
        &self,
        job: impl FnOnce(&mut Worker) -> T + Send + 'static,
    ) -> Option<T> {
        let open = self.open.as_ref()?;
        let (tx, rx) = mpsc::sync_channel(1);
        open.tx
            .send(Msg::Control(Box::new(move |worker| {
                let _ = tx.send(job(worker));
            })))
            .ok()?;
        rx.recv().ok()
    }

    /// The sidebar last stored: the one MC's the client was last opened at,
    /// or with a non-empty `origin` that MC's, another's being dropped.
    /// Blocks until it is read.
    pub fn shell(&self, origin: &str) -> Shell {
        let Some(open) = &self.open else {
            return Shell::default();
        };
        let (tx, rx) = mpsc::sync_channel(1);
        let origin = origin.to_owned();
        let _ = open.tx.send(Msg::Job(Box::new(move |worker: &mut Worker| {
            let shell = if worker.usable() {
                worker.read_shell(origin)
            } else {
                Shell::default()
            };
            let _ = tx.send(shell);
        })));
        rx.recv().unwrap_or_default()
    }

    pub fn store_shell(&self, origin: &str, mcs: Vec<ShellMcUpdate>) {
        let origin = origin.to_owned();
        self.post(move |worker| {
            if !worker.usable() {
                return;
            }
            if worker.lost.shells.contains(&origin) {
                if !worker.drop_shell(&origin) {
                    return;
                }
                worker.lost.shells.remove(&origin);
            }
            // A sidebar that missed a change would be resumed from the wrong
            // version.
            if !worker.whole(|w| w.apply_shell(&origin, &mcs)) && !worker.drop_shell(&origin) {
                worker.lost.shells.insert(origin);
            }
        });
    }

    /// `reply` runs in a later [`LocalCache::deliver`] on this thread, never
    /// from inside the call. A reply whose owner may be gone by then holds
    /// it weakly (desktop-qt's `context`).
    pub fn load_thread(&self, key: &str, reply: impl FnOnce(Thread) + 'static) {
        let Some(open) = &self.open else {
            // Never synchronous, so callers see one order either way.
            self.unopened.borrow_mut().push_back(Box::new(reply));
            self.wake();
            return;
        };
        let id = self.next.get();
        self.next.set(id + 1);
        self.pending.borrow_mut().insert(id, Box::new(reply));
        let key = key.to_owned();
        let _ = open.tx.send(Msg::Job(Box::new(move |worker: &mut Worker| {
            let thread = if !worker.usable() || worker.lost.threads.contains(&key) {
                Thread::default()
            } else {
                worker.read_thread(&key)
            };
            let _ = worker.replies.send((id, thread));
            let wake = worker
                .wake
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .clone();
            if let Some(wake) = wake {
                wake();
            }
        })));
    }

    pub fn store_thread(&self, update: ThreadUpdate) {
        self.post(move |worker| {
            if !worker.usable() {
                return;
            }
            if worker.lost.threads.contains(&update.key) {
                if !worker.drop_thread(&update.key) {
                    return;
                }
                worker.lost.threads.remove(&update.key);
            }
            // A copy that missed a change no longer matches its cursor.
            if !worker.whole(|w| w.apply_thread(&update)) && !worker.drop_thread(&update.key) {
                worker.lost.threads.insert(update.key);
            }
        });
    }

    /// Drops the windowed entities of runs before `floor`, which becomes the
    /// copy's floor; a copy that already starts later is left as it is.
    pub fn trim_thread(&self, key: &str, floor: i64) {
        let key = key.to_owned();
        self.post(move |worker| {
            if !worker.usable() || worker.lost.threads.contains(&key) {
                return;
            }
            let Some(db) = &worker.db else { return };
            let raised = logged(
                "UPDATE threads SET floor",
                db.execute(
                    "UPDATE threads SET floor = ?1 WHERE key = ?2 AND (floor IS NULL OR floor < ?1)",
                    params![floor, key],
                ),
            );
            if raised.unwrap_or(0) == 0 {
                return;
            }
            let _ = logged(
                "DELETE FROM entities",
                db.execute(
                    "DELETE FROM entities WHERE thread = ?1 AND run_ord < ?2",
                    params![key, floor],
                ),
            );
        });
    }

    pub fn forget_thread(&self, key: &str) {
        let key = key.to_owned();
        self.post(move |worker| {
            if worker.usable() && !worker.drop_thread(&key) {
                worker.lost.threads.insert(key);
            }
        });
    }

    pub fn forget_environment(&self, environment_id: &str) {
        let prefix = format!("{environment_id}:");
        self.post(move |worker| {
            if !worker.usable() {
                return;
            }
            let Some(db) = &worker.db else { return };
            let length = prefix.chars().count() as i64;
            // Their cursors first; while those stay, so do the copies they
            // vouch for.
            if logged(
                "DELETE FROM threads",
                db.execute(
                    "DELETE FROM threads WHERE substr(key, 1, ?1) = ?2",
                    params![length, prefix],
                ),
            )
            .is_none()
            {
                return;
            }
            let _ = logged(
                "DELETE FROM entities",
                db.execute(
                    "DELETE FROM entities WHERE substr(thread, 1, ?1) = ?2",
                    params![length, prefix],
                ),
            );
        });
    }

    /// Starts the database over, so nothing kept stays on disk: the client
    /// left its MC for good. Blocks until it is done. False when the file
    /// could be neither removed nor emptied: what it holds is not read, but
    /// is still on disk.
    pub fn clear(&self) -> bool {
        if self.open.is_none() {
            return true;
        }
        self.control(|worker| worker.start_over()).unwrap_or(false)
    }

    /// Runs the `load_thread` replies that are ready.
    pub fn deliver(&self) {
        loop {
            let reply = self.unopened.borrow_mut().pop_front();
            match reply {
                Some(reply) => reply(Thread::default()),
                None => break,
            }
        }
        let Some(open) = &self.open else { return };
        while let Ok((id, thread)) = open.replies.try_recv() {
            // The borrow ends before the reply runs: it may load again.
            let reply = self.pending.borrow_mut().remove(&id);
            if let Some(reply) = reply {
                reply(thread);
            }
        }
    }

    /// Returns once everything asked for so far is done and every
    /// `load_thread` reply has run. Tests and shutdown wait on this.
    pub fn drain(&self) {
        let _ = self.control(|_| ());
        self.deliver();
    }
}

impl Drop for LocalCache {
    fn drop(&mut self) {
        let Some(open) = &mut self.open else { return };
        let _ = open.tx.send(Msg::Quit);
        if let Some(thread) = open.thread.take() {
            let _ = thread.join();
        }
    }
}

/// What can no longer be vouched for: a copy that missed a change and could
/// not be dropped either. It is not read, and not changed, until it can be
/// dropped.
#[derive(Default)]
struct Lost {
    /// By key.
    threads: HashSet<String>,
    /// By origin.
    shells: HashSet<String>,
    /// After a commit that failed: every copy, until all of them are dropped.
    everything: bool,
}

/// Owns the connection, on the cache's thread.
struct Worker {
    db: Option<Connection>,
    path: PathBuf,
    lost: Lost,
    replies: Sender<(u64, Thread)>,
    wake: Arc<Mutex<Option<Wake>>>,
}

fn logged<T>(what: &str, result: rusqlite::Result<T>) -> Option<T> {
    match result {
        Ok(value) => Some(value),
        Err(error) => {
            eprintln!("[cache] {what}: {error}");
            None
        }
    }
}

fn json(object: &Map<String, Value>) -> Vec<u8> {
    serde_json::to_vec(object).unwrap_or_default()
}

fn object(bytes: &[u8]) -> Map<String, Value> {
    serde_json::from_slice(bytes).unwrap_or_default()
}

const TABLES: &[&str] = &[
    // The sidebar, by the origin the client was opened at.
    "CREATE TABLE shell_mcs(origin TEXT NOT NULL, mc TEXT NOT NULL, epoch TEXT, rev INTEGER, environment BLOB NOT NULL, \
     PRIMARY KEY(origin, mc)) WITHOUT ROWID",
    "CREATE TABLE shell_rows(origin TEXT NOT NULL, mc TEXT NOT NULL, id TEXT NOT NULL, kind TEXT NOT NULL, row BLOB NOT NULL, \
     PRIMARY KEY(origin, mc, id)) WITHOUT ROWID",
    // Threads by "environmentId:threadId"; `used` orders them by when they
    // were last opened.
    "CREATE TABLE threads(key TEXT PRIMARY KEY, handle TEXT NOT NULL, cursor INTEGER NOT NULL, floor INTEGER, used INTEGER NOT NULL) \
     WITHOUT ROWID",
    "CREATE TABLE entities(thread TEXT NOT NULL, kind TEXT NOT NULL, id TEXT NOT NULL, run_ord INTEGER, json BLOB NOT NULL, \
     PRIMARY KEY(thread, kind, id)) WITHOUT ROWID",
];

impl Worker {
    /// A database of another schema, or one SQLite cannot read, is started over.
    fn open(&mut self) -> bool {
        self.ready() || self.start_over()
    }

    fn serve(&mut self, rx: Receiver<Msg>) {
        let mut next = None;
        loop {
            let msg = match next.take() {
                Some(msg) => msg,
                None => match rx.recv() {
                    Ok(msg) => msg,
                    Err(_) => break,
                },
            };
            match msg {
                Msg::Quit => break,
                Msg::Control(job) => job(self),
                Msg::Job(job) => {
                    // Everything asked for since the last time, in one transaction.
                    let mut jobs = vec![job];
                    loop {
                        match rx.try_recv() {
                            Ok(Msg::Job(job)) => jobs.push(job),
                            Ok(other) => {
                                next = Some(other);
                                break;
                            }
                            Err(_) => break,
                        }
                    }
                    self.flush(jobs);
                }
            }
        }
        self.db = None;
    }

    fn flush(&mut self, jobs: Vec<Job>) {
        // Without a transaction each change still lands whole or not at all:
        // it is a savepoint of its own (whole()).
        let transaction = self
            .db
            .as_ref()
            .is_some_and(|db| db.execute_batch("BEGIN").is_ok());
        for job in jobs {
            job(self);
        }
        if !transaction {
            return;
        }
        let Some(db) = &self.db else { return };
        let Err(error) = db.execute_batch("COMMIT") else {
            return;
        };
        eprintln!("[cache] not saved: {error}");
        // A commit that failed is still open, and would swallow every later
        // one. What it held is lost, and the changes that follow build on
        // it: nothing kept can be trusted to match its cursor, so nothing is
        // kept.
        let _ = db.execute_batch("ROLLBACK");
        self.lost.everything = true;
        self.usable();
    }

    fn ready(&mut self) -> bool {
        let db = match Connection::open(&self.path) {
            Ok(db) => db,
            Err(error) => {
                eprintln!("[cache] {}: {error}", self.path.display());
                return false;
            }
        };
        let _ = db.pragma_update(None, "journal_mode", "WAL");
        let _ = db.pragma_update(None, "synchronous", "NORMAL");
        let _ = db.busy_timeout(std::time::Duration::from_millis(2000));
        let ready = (|| -> rusqlite::Result<bool> {
            db.execute_batch(
                "CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID",
            )?;
            let schema: Option<String> = db
                .query_row("SELECT value FROM meta WHERE key = 'schema'", [], |row| {
                    row.get(0)
                })
                .optional()?;
            if let Some(schema) = schema {
                return Ok(schema.parse::<i64>().ok() == Some(SCHEMA));
            }
            db.execute_batch("BEGIN")?;
            for table in TABLES {
                db.execute_batch(table)?;
            }
            db.execute(
                "INSERT INTO meta(key, value) VALUES('schema', ?1)",
                params![SCHEMA.to_string()],
            )?;
            db.execute_batch("COMMIT")?;
            Ok(true)
        })();
        let ready = logged(&self.path.display().to_string(), ready).unwrap_or(false);
        // Kept even when not ready: start_over closes it.
        self.db = Some(db);
        ready
    }

    /// An empty database in place of the file, and of its journal: nothing
    /// of what was kept stays on disk. A file that cannot be removed is
    /// emptied where it is, its freed pages overwritten. False when neither
    /// could be done: what it still holds is then not read, and is dropped
    /// as soon as it can be.
    fn start_over(&mut self) -> bool {
        self.db = None;
        for suffix in ["", "-wal", "-shm"] {
            let mut path = self.path.clone().into_os_string();
            path.push(suffix);
            let _ = std::fs::remove_file(path);
        }
        self.lost = Lost::default();
        if !self.path.exists() {
            if self.ready() {
                return true;
            }
            self.db = None;
            return false;
        }
        if self.ready() {
            if let Some(db) = &self.db {
                let _ = db.pragma_update(None, "secure_delete", "ON");
            }
            if self.drop_everything() {
                if let Some(db) = &self.db {
                    let _ = db.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(()));
                }
                return true;
            }
        }
        eprintln!(
            "[cache] {} could not be removed or emptied",
            self.path.display()
        );
        self.lost.everything = true;
        false
    }

    fn run(&self, sql: &str, values: impl rusqlite::Params) -> Option<usize> {
        let db = self.db.as_ref()?;
        logged(sql, db.execute(sql, values))
    }

    /// Runs `change` so that it lands whole or not at all; false when it did not.
    fn whole(&mut self, change: impl FnOnce(&mut Worker) -> bool) -> bool {
        let _ = self.run_batch("SAVEPOINT change");
        let landed = change(self);
        if !landed {
            let _ = self.run_batch("ROLLBACK TO change");
        }
        let _ = self.run_batch("RELEASE change");
        landed
    }

    fn run_batch(&self, sql: &str) -> Option<()> {
        let db = self.db.as_ref()?;
        logged(sql, db.execute_batch(sql))
    }

    /// A copy is what its cursor says it is, so the cursor goes first: rows
    /// left without one are no copy, while a cursor left without its rows
    /// would pass for a whole one. False when the cursor could not be taken
    /// away.
    fn drop_thread(&self, key: &str) -> bool {
        if self
            .run("DELETE FROM threads WHERE key = ?1", [key])
            .is_none()
        {
            return false;
        }
        let _ = self.run("DELETE FROM entities WHERE thread = ?1", [key]);
        true
    }

    /// The thread list kept of one MC goes the same way: its versions first.
    fn drop_shell(&self, origin: &str) -> bool {
        if self
            .run("DELETE FROM shell_mcs WHERE origin = ?1", [origin])
            .is_none()
        {
            return false;
        }
        let _ = self.run("DELETE FROM shell_rows WHERE origin = ?1", [origin]);
        true
    }

    /// Every copy goes, cursors and versions first; whether all of them did.
    fn drop_everything(&mut self) -> bool {
        let threads = self.run("DELETE FROM threads", []).is_some();
        if threads {
            let _ = self.run("DELETE FROM entities", []);
        }
        let shells = self.run("DELETE FROM shell_mcs", []).is_some();
        if shells {
            let _ = self.run("DELETE FROM shell_rows", []);
        }
        if !threads || !shells {
            return false;
        }
        self.lost = Lost::default();
        true
    }

    /// Whether the cache holds anything to read or to bring up to date:
    /// always, but after a failed commit only once everything it held is
    /// dropped.
    fn usable(&mut self) -> bool {
        self.db.is_some() && (!self.lost.everything || self.drop_everything())
    }

    fn next_use(db: &Connection) -> i64 {
        db.query_row(
            "SELECT COALESCE(MAX(used), 0) + 1 FROM threads",
            [],
            |row| row.get(0),
        )
        .unwrap_or(1)
    }

    fn apply_thread(&mut self, update: &ThreadUpdate) -> bool {
        let Some(db) = &self.db else { return false };
        let applied = (|| -> rusqlite::Result<()> {
            let floor = update.cursor.floor;
            if update.replace {
                db.execute("DELETE FROM entities WHERE thread = ?1", [&update.key])?;
                db.execute(
                    "INSERT OR REPLACE INTO threads(key, handle, cursor, floor, used) VALUES(?1, ?2, ?3, ?4, ?5)",
                    params![
                        update.key,
                        update.cursor.handle,
                        update.cursor.offset,
                        floor,
                        Self::next_use(db)
                    ],
                )?;
            } else {
                let changed = db.execute(
                    "UPDATE threads SET handle = ?1, cursor = ?2, floor = ?3 WHERE key = ?4",
                    params![
                        update.cursor.handle,
                        update.cursor.offset,
                        floor,
                        update.key
                    ],
                )?;
                // Forgotten since (its thread was deleted, or others pushed
                // it out): there is no copy for the change to bring up to date.
                if changed == 0 {
                    return Ok(());
                }
            }
            let mut gone =
                db.prepare("DELETE FROM entities WHERE thread = ?1 AND kind = ?2 AND id = ?3")?;
            for (kind, id) in &update.gone {
                gone.execute(params![update.key, kind, id])?;
            }
            let mut put = db.prepare(
                "INSERT OR REPLACE INTO entities(thread, kind, id, run_ord, json) VALUES(?1, ?2, ?3, ?4, ?5)",
            )?;
            for entity in &update.put {
                put.execute(params![
                    update.key,
                    entity.kind,
                    entity.id,
                    entity.run,
                    json(&entity.fields)
                ])?;
            }
            if !update.replace {
                return Ok(());
            }
            // A thread just stored may push the least recently opened ones out.
            let mut old =
                db.prepare("SELECT key FROM threads ORDER BY used DESC LIMIT -1 OFFSET ?1")?;
            let evicted = old
                .query_map([THREADS], |row| row.get::<_, String>(0))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            drop(old);
            for key in evicted {
                self.drop_thread(&key);
            }
            Ok(())
        })();
        logged("thread", applied).is_some()
    }

    fn read_thread(&self, key: &str) -> Thread {
        let Some(db) = &self.db else {
            return Thread::default();
        };
        let read = (|| -> rusqlite::Result<Thread> {
            let cursor = db
                .query_row(
                    "SELECT handle, cursor, floor FROM threads WHERE key = ?1",
                    [key],
                    |row| {
                        Ok(Cursor {
                            handle: row.get(0)?,
                            offset: row.get(1)?,
                            floor: row.get(2)?,
                        })
                    },
                )
                .optional()?;
            let Some(cursor) = cursor else {
                return Ok(Thread::default());
            };
            let _ = logged(
                "UPDATE threads SET used",
                db.execute(
                    "UPDATE threads SET used = ?1 WHERE key = ?2",
                    params![Self::next_use(db), key],
                ),
            );
            let mut rows =
                db.prepare("SELECT kind, id, run_ord, json FROM entities WHERE thread = ?1")?;
            let entities = rows
                .query_map([key], |row| {
                    Ok(Entity {
                        kind: row.get(0)?,
                        id: row.get(1)?,
                        run: row.get(2)?,
                        fields: object(&row.get::<_, Vec<u8>>(3)?),
                    })
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            Ok(Thread { cursor, entities })
        })();
        logged("read thread", read).unwrap_or_default()
    }

    fn apply_shell(&mut self, origin: &str, mcs: &[ShellMcUpdate]) -> bool {
        let Some(db) = &self.db else { return false };
        let applied = (|| -> rusqlite::Result<()> {
            let mut put = db.prepare(
                "INSERT OR REPLACE INTO shell_rows(origin, mc, id, kind, row) VALUES(?1, ?2, ?3, ?4, ?5)",
            )?;
            let mut gone =
                db.prepare("DELETE FROM shell_rows WHERE origin = ?1 AND mc = ?2 AND id = ?3")?;
            for mc in mcs {
                if mc.removed || mc.reset {
                    db.execute(
                        "DELETE FROM shell_rows WHERE origin = ?1 AND mc = ?2",
                        params![origin, mc.mc],
                    )?;
                }
                if mc.removed {
                    db.execute(
                        "DELETE FROM shell_mcs WHERE origin = ?1 AND mc = ?2",
                        params![origin, mc.mc],
                    )?;
                    continue;
                }
                let epoch = (!mc.epoch.is_empty()).then_some(&mc.epoch);
                if mc.reset {
                    db.execute(
                        "INSERT OR REPLACE INTO shell_mcs(origin, mc, epoch, rev, environment) VALUES(?1, ?2, ?3, ?4, ?5)",
                        params![origin, mc.mc, epoch, mc.rev, json(&mc.environment)],
                    )?;
                } else {
                    let changed = db.execute(
                        "UPDATE shell_mcs SET epoch = ?1, rev = ?2, environment = ?3 WHERE origin = ?4 AND mc = ?5",
                        params![epoch, mc.rev, json(&mc.environment), origin, mc.mc],
                    )?;
                    // Only the rows that changed, for an MC whose rows are not
                    // kept (they were dropped): kept, they would pass for all
                    // of its rows.
                    if changed == 0 {
                        continue;
                    }
                }
                for id in &mc.gone {
                    gone.execute(params![origin, mc.mc, id])?;
                }
                for row in &mc.put {
                    put.execute(params![origin, mc.mc, row.id, row.kind, json(&row.fields)])?;
                }
            }
            Ok(())
        })();
        logged("shell", applied).is_some()
    }

    fn read_shell(&mut self, origin: String) -> Shell {
        let Some(db) = &self.db else {
            return Shell::default();
        };
        let origin = if origin.is_empty() {
            let last = logged(
                "SELECT origin",
                db.query_row("SELECT origin FROM shell_mcs LIMIT 1", [], |row| {
                    row.get::<_, String>(0)
                })
                .optional(),
            );
            match last.flatten() {
                Some(origin) => origin,
                None => return Shell::default(),
            }
        } else {
            // One MC's sidebar is kept: the one the client was last opened at.
            if logged(
                "DELETE FROM shell_mcs",
                db.execute("DELETE FROM shell_mcs WHERE origin <> ?1", [&origin]),
            )
            .is_some()
            {
                let _ = logged(
                    "DELETE FROM shell_rows",
                    db.execute("DELETE FROM shell_rows WHERE origin <> ?1", [&origin]),
                );
            }
            origin
        };
        if self.lost.shells.contains(&origin) {
            return Shell::default();
        }
        let read = (|| -> rusqlite::Result<Vec<ShellMc>> {
            let mut members =
                db.prepare("SELECT mc, epoch, rev, environment FROM shell_mcs WHERE origin = ?1")?;
            let mut mcs = members
                .query_map([&origin], |row| {
                    Ok(ShellMc {
                        mc: row.get(0)?,
                        epoch: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                        rev: row.get::<_, Option<i64>>(2)?.unwrap_or(0),
                        environment: object(&row.get::<_, Vec<u8>>(3)?),
                        rows: Vec::new(),
                    })
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            let mut rows =
                db.prepare("SELECT mc, id, kind, row FROM shell_rows WHERE origin = ?1")?;
            let mut found = rows.query([&origin])?;
            while let Some(row) = found.next()? {
                let name: String = row.get(0)?;
                if let Some(mc) = mcs.iter_mut().find(|mc| mc.mc == name) {
                    mc.rows.push(ShellRow {
                        id: row.get(1)?,
                        kind: row.get(2)?,
                        fields: object(&row.get::<_, Vec<u8>>(3)?),
                    });
                }
            }
            Ok(mcs)
        })();
        let Some(mcs) = logged("read shell", read) else {
            return Shell::default();
        };
        Shell {
            origin: if mcs.is_empty() {
                String::new()
            } else {
                origin
            },
            mcs,
        }
    }
}
