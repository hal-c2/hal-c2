//! The directories a `LocalFolderModel` shows, watched for changes made
//! outside it: QFileSystemModel's file watching, and the root's parent that
//! `QFileSystemWatcher` watched in desktop-qt.
//!
//! The OS watcher runs on a thread of its own. What it sees goes on the
//! "folders" side stream ([`wire`]) with the model it is for, and the stream's
//! handler hands it to that model on the Engine thread.
//!
//! DECISION: the stream coalesces per model and path, and never waits. A
//! path that changed again before the UI looked is one change (the model
//! reads the folder again either way), so a burst of writes to one file
//! costs one slot. The watcher's thread must not wait: `notify` answers a
//! `watch` from the UI thread on that same thread, so a sender waiting for
//! the UI would hold the UI waiting for it. A path refused by a full stream
//! instead marks its model, and the next run reads again every folder that
//! model shows: nothing is lost, and what waits stays bounded by the
//! capacity and the number of models.

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::hash::{DefaultHasher, Hash, Hasher};
use std::path::{Path, PathBuf};
use std::rc::{Rc, Weak};
use std::sync::{Arc, Mutex, PoisonError};

use ljos::prelude::{Engine, ObjectId};
use ljos::{BatchPolicy, BatchSender, CoalesceKey};
use notify::{RecommendedWatcher, RecursiveMode, Watcher};

use super::{Model, State};
use crate::streams::Wire;

/// How many changed paths wait at most: more than a folder view shows at
/// once, so a refusal (and the full reread it costs) takes a flood.
pub const CAPACITY: usize = 1024;

/// What the watcher threads hand the Engine thread: the stream, and the
/// models a full stream refused a path of.
#[derive(Clone)]
struct Shared {
    changes: BatchSender<(u64, PathBuf)>,
    overflowed: Arc<Mutex<HashSet<u64>>>,
}

impl Shared {
    fn push(&self, model: u64, paths: Vec<PathBuf>) {
        for path in paths {
            if self.changes.send((model, path)).is_err() {
                self.overflowed
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .insert(model);
            }
        }
    }
}

fn key((model, path): &(u64, PathBuf)) -> CoalesceKey {
    let mut hasher = DefaultHasher::new();
    (model, path).hash(&mut hasher);
    CoalesceKey(hasher.finish())
}

/// The engine's models that watch, and the stream their watchers share.
#[derive(Default)]
struct Hub {
    shared: RefCell<Option<Shared>>,
    models: RefCell<HashMap<u64, (ObjectId, Weak<State>)>>,
    next: Cell<u64>,
}

impl Hub {
    fn of(engine: &Engine) -> Rc<Hub> {
        engine.extension::<Hub>()
    }
}

/// Makes the "folders" stream the models' watchers made from now on feed.
pub fn wire(engine: &Engine, wire: &mut impl Wire) {
    let overflowed = Arc::new(Mutex::new(HashSet::new()));
    let changes = wire.stream("folders", CAPACITY, BatchPolicy::Coalesce(key), {
        let overflowed = overflowed.clone();
        move |engine, run| {
            let run: Vec<_> = run.collect();
            deliver(engine, run, &overflowed);
        }
    });
    *Hub::of(engine).shared.borrow_mut() = Some(Shared {
        changes,
        overflowed,
    });
}

/// Hands each model what its directories saw. On the Engine thread.
fn deliver(engine: &Engine, run: Vec<(u64, PathBuf)>, overflowed: &Mutex<HashSet<u64>>) {
    let hub = Hub::of(engine);
    let model = |id: u64| {
        let found = hub.models.borrow().get(&id).cloned();
        let (obj, state) = found?;
        match state.upgrade() {
            Some(state) if engine.is_alive(obj) => Some(Model::new(engine, obj, state)),
            _ => {
                hub.models.borrow_mut().remove(&id);
                None
            }
        }
    };
    let overflowed =
        std::mem::take(&mut *overflowed.lock().unwrap_or_else(PoisonError::into_inner));
    for (id, path) in run {
        if !overflowed.contains(&id)
            && let Some(model) = model(id)
        {
            model.changed(&path);
        }
    }
    for id in overflowed {
        if let Some(model) = model(id) {
            model.changed_everywhere();
        }
    }
}

/// One model's watcher: made on the first directory it is given.
pub(super) struct Watch {
    id: u64,
    hub: Rc<Hub>,
    watcher: Option<RecommendedWatcher>,
    dirs: HashSet<PathBuf>,
}

impl Watch {
    pub fn new(engine: &Engine, obj: ObjectId, state: &Rc<State>) -> Watch {
        let hub = Hub::of(engine);
        let id = hub.next.get() + 1;
        hub.next.set(id);
        hub.models
            .borrow_mut()
            .insert(id, (obj, Rc::downgrade(state)));
        Watch {
            id,
            hub,
            watcher: None,
            dirs: HashSet::new(),
        }
    }

    /// Watches exactly `dirs` (each one level, not what is below). A
    /// directory that cannot be watched is not.
    pub fn set(&mut self, dirs: HashSet<PathBuf>) {
        if dirs == self.dirs {
            return;
        }
        if dirs.is_empty() {
            self.watcher = None;
            self.dirs = dirs;
            return;
        }
        // The stream as it is now: a model made before the shell wired
        // its streams watches once they are.
        let shared = self.hub.shared.borrow().clone();
        if self.watcher.is_none()
            && let Some(shared) = shared
        {
            let id = self.id;
            self.watcher =
                notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
                    if let Ok(event) = event
                        && !event.kind.is_access()
                        && !event.paths.is_empty()
                    {
                        shared.push(id, event.paths);
                    }
                })
                .ok();
        }
        let Some(watcher) = self.watcher.as_mut() else {
            self.dirs.clear();
            return;
        };
        for gone in self.dirs.difference(&dirs) {
            let _ = watcher.unwatch(gone);
        }
        let mut watching = HashSet::new();
        for dir in &dirs {
            if self.dirs.contains(dir) || watcher.watch(dir, RecursiveMode::NonRecursive).is_ok() {
                watching.insert(dir.clone());
            }
        }
        self.dirs = watching;
    }
}

/// `path`'s folder, when it has one.
pub(super) fn parent(path: &Path) -> Option<&Path> {
    path.parent().filter(|p| !p.as_os_str().is_empty())
}
