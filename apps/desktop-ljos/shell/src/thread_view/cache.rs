//! What a timeline keeps of its thread between connections and runs: the
//! `cache::` types of desktop-qt's LocalCache.h, and the two calls the
//! timeline makes on it.
//!
//! TODO(port): LocalCache::storeThread / LocalCache::trimThread /
//! LocalCache::loadThread. The LocalCache port (another worker's) owns
//! these types and implements [`ThreadCache`]; until then nothing does, and
//! a timeline without a cache keeps nothing, as desktop-qt's does.

use super::summary::Obj;

/// One entity of a thread's stream, as the timeline holds it.
#[derive(Clone, Debug, PartialEq)]
pub struct Entity {
    pub kind: String,
    pub id: String,
    pub fields: Obj,
    /// The ordinal of its run, for the kinds a window bounds (turn items
    /// and messages of a run); none for the rest, which are held whole.
    pub run: Option<i64>,
}

/// Where a copy of a thread stands: the MC log it follows (`handle`), the
/// offset it reflects, and the first run of its window (none: it reaches
/// the start of the thread). `offset` is negative when there is no copy.
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

/// A thread's copy as the cache held it.
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
    /// "environmentId:threadId"
    pub key: String,
    pub cursor: Cursor,
    /// After a snapshot: `put` is the whole copy. Otherwise a change to a
    /// copy that is there; one the cache no longer holds is left alone.
    pub replace: bool,
    pub put: Vec<Entity>,
    /// (kind, id)
    pub gone: Vec<(String, String)>,
}

/// Where a timeline's copy is kept. Both calls are queued: they return at
/// once.
pub trait ThreadCache {
    fn store_thread(&self, update: ThreadUpdate);
    /// Drops the turns before the run `floor` from the copy of `key`, and
    /// raises its cursor's floor to it; nothing when it is already there.
    fn trim_thread(&self, key: &str, floor: i64);
}
