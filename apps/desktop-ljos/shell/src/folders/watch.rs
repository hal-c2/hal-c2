//! The directories a `LocalFolderModel` shows, watched for changes made
//! outside it: QFileSystemModel's file watching, and the root's parent that
//! `QFileSystemWatcher` watched in desktop-qt.
//!
//! The OS watcher runs on a thread of its own. What it sees queues here with
//! the model it is for, and the shell hears of it through the waker
//! ([`set_wake`]): it then calls [`deliver`] on the Engine thread. A headless
//! host (a test) waits on its own waker instead.

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::rc::{Rc, Weak};
use std::sync::{Arc, Mutex, PoisonError};

use ljos::prelude::{Engine, ObjectId};
use notify::{RecommendedWatcher, RecursiveMode, Watcher};

use super::{Model, State};

type Wake = Arc<dyn Fn() + Send + Sync>;

/// What the watcher threads leave for the Engine thread.
#[derive(Default)]
struct Shared {
    events: Mutex<Vec<(u64, PathBuf)>>,
    wake: Mutex<Option<Wake>>,
}

impl Shared {
    fn push(&self, model: u64, paths: Vec<PathBuf>) {
        {
            let mut events = self.events.lock().unwrap_or_else(PoisonError::into_inner);
            events.extend(paths.into_iter().map(|p| (model, p)));
        }
        self.wake();
    }

    fn wake(&self) {
        let wake = self
            .wake
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        if let Some(wake) = wake {
            wake();
        }
    }
}

/// The engine's models that watch, and the queue their watchers share.
#[derive(Default)]
struct Hub {
    shared: Arc<Shared>,
    models: RefCell<HashMap<u64, (ObjectId, Weak<State>)>>,
    next: Cell<u64>,
}

impl Hub {
    fn of(engine: &Engine) -> Rc<Hub> {
        engine.extension::<Hub>()
    }
}

/// Says what to run, on any thread, when [`deliver`] has something to do:
/// post a message to the Engine thread, which calls [`deliver`].
pub fn set_wake(engine: &Engine, wake: impl Fn() + Send + Sync + 'static) {
    let wake: Wake = Arc::new(wake);
    *Hub::of(engine)
        .shared
        .wake
        .lock()
        .unwrap_or_else(PoisonError::into_inner) = Some(wake);
}

/// Hands each model what its directories saw. On the Engine thread.
pub fn deliver(engine: &Engine) {
    let hub = Hub::of(engine);
    let events = std::mem::take(
        &mut *hub
            .shared
            .events
            .lock()
            .unwrap_or_else(PoisonError::into_inner),
    );
    let mut seen = HashSet::new();
    for (id, path) in events {
        if !seen.insert((id, path.clone())) {
            continue;
        }
        let found = hub.models.borrow().get(&id).cloned();
        let Some((obj, state)) = found else {
            continue;
        };
        match state.upgrade() {
            Some(state) if engine.is_alive(obj) => Model::new(engine, obj, state).changed(&path),
            _ => {
                hub.models.borrow_mut().remove(&id);
            }
        }
    }
}

/// One model's watcher: made on the first directory it is given.
pub(super) struct Watch {
    id: u64,
    shared: Arc<Shared>,
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
            shared: hub.shared.clone(),
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
        if self.watcher.is_none() {
            let (shared, id) = (self.shared.clone(), self.id);
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
