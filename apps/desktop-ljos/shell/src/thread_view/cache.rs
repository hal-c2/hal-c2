//! What a timeline keeps of its thread between connections and runs: the
//! [`crate::cache`] types, and the two calls the timeline makes on the
//! cache. The shell's [`LocalCache`] is one; tests keep copies in memory.
//! ThreadStore loads the copy and hands it to [`super::timeline::Timeline::restore`].

pub use crate::cache::{Cursor, Entity, LocalCache, Thread, ThreadUpdate};

/// Where a timeline's copy is kept. Both calls are queued: they return at
/// once.
pub trait ThreadCache {
    fn store_thread(&self, update: ThreadUpdate);
    /// Drops the turns before the run `floor` from the copy of `key`, and
    /// raises its cursor's floor to it; nothing when it is already there.
    fn trim_thread(&self, key: &str, floor: i64);
}

impl ThreadCache for LocalCache {
    fn store_thread(&self, update: ThreadUpdate) {
        LocalCache::store_thread(self, update);
    }

    fn trim_thread(&self, key: &str, floor: i64) {
        LocalCache::trim_thread(self, key, floor);
    }
}
