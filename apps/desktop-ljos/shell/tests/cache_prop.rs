//! The cache against a model of it: any order of stores, changes, trims,
//! forgets, reads and restarts leaves what the model says, because a read
//! sees every write asked for before it and a copy is only ever what its
//! cursor says.

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;

use hal_c2_shell::cache::{
    Cursor, Entity, LocalCache, Shell, ShellMcUpdate, ShellRow, Thread, ThreadUpdate,
};
use proptest::prelude::*;
use serde_json::{Map, Value, json};

type Entities = BTreeMap<String, (Option<i64>, i64)>;
/// mc -> (rev, row id -> n)
type Mcs = BTreeMap<String, (i64, BTreeMap<String, i64>)>;

#[derive(Clone, Debug)]
enum Op {
    Snapshot {
        key: usize,
        offset: i64,
        put: Vec<(usize, Option<i64>, i64)>,
    },
    Change {
        key: usize,
        offset: i64,
        put: Vec<(usize, Option<i64>, i64)>,
        gone: Vec<usize>,
    },
    Trim {
        key: usize,
        floor: i64,
    },
    Forget {
        key: usize,
    },
    ForgetEnvironment {
        env: usize,
    },
    Load {
        key: usize,
    },
    StoreShell {
        origin: usize,
        mc: usize,
        removed: bool,
        reset: bool,
        rev: i64,
        put: Vec<(usize, i64)>,
        gone: Vec<usize>,
    },
    ReadShell {
        origin: Option<usize>,
    },
    Reopen,
}

const KEYS: &[&str] = &["env-a:t1", "env-a:t2", "env-ab:t1", "env-b:t1"];
const ENVS: &[&str] = &["env-a", "env-ab", "env-b"];
const IDS: &[&str] = &["a", "b", "c", "d"];
const ORIGINS: &[&str] = &["http://one:1", "http://two:2"];
const MCS: &[&str] = &["mc-a", "mc-b"];

fn entities() -> impl Strategy<Value = Vec<(usize, Option<i64>, i64)>> {
    prop::collection::vec((0..IDS.len(), prop::option::of(0i64..5), 0i64..100), 0..4)
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        (0..KEYS.len(), 0i64..50, entities()).prop_map(|(key, offset, put)| Op::Snapshot {
            key,
            offset,
            put
        }),
        (
            0..KEYS.len(),
            0i64..50,
            entities(),
            prop::collection::vec(0..IDS.len(), 0..3)
        )
            .prop_map(|(key, offset, put, gone)| Op::Change {
                key,
                offset,
                put,
                gone
            }),
        (0..KEYS.len(), 0i64..5).prop_map(|(key, floor)| Op::Trim { key, floor }),
        (0..KEYS.len()).prop_map(|key| Op::Forget { key }),
        (0..ENVS.len()).prop_map(|env| Op::ForgetEnvironment { env }),
        (0..KEYS.len()).prop_map(|key| Op::Load { key }),
        (
            0..ORIGINS.len(),
            0..MCS.len(),
            prop::bool::weighted(0.15),
            any::<bool>(),
            0i64..20,
            prop::collection::vec((0..IDS.len(), 0i64..100), 0..3),
            prop::collection::vec(0..IDS.len(), 0..2),
        )
            .prop_map(
                |(origin, mc, removed, reset, rev, put, gone)| Op::StoreShell {
                    origin,
                    mc,
                    removed,
                    reset,
                    rev,
                    put,
                    gone
                }
            ),
        prop::option::of(0..ORIGINS.len()).prop_map(|origin| Op::ReadShell { origin }),
        Just(Op::Reopen),
    ]
}

fn fields(n: i64) -> Map<String, Value> {
    json!({"n": n}).as_object().cloned().unwrap()
}

fn to_entities(put: &[(usize, Option<i64>, i64)]) -> Vec<Entity> {
    put.iter()
        .map(|&(id, run, n)| Entity {
            kind: "item".into(),
            id: IDS[id].into(),
            fields: fields(n),
            run,
        })
        .collect()
}

#[derive(Default, Debug)]
struct Model {
    threads: BTreeMap<String, (Cursor, Entities)>,
    /// origin -> its MCs
    shells: BTreeMap<String, Mcs>,
}

fn load(cache: &LocalCache, key: &str) -> Thread {
    let found = Rc::new(RefCell::new(None));
    let slot = found.clone();
    cache.load_thread(key, move |thread| *slot.borrow_mut() = Some(thread));
    cache.drain();
    found.borrow_mut().take().unwrap()
}

fn seen(thread: &Thread) -> Option<(Cursor, Entities)> {
    thread.found().then(|| {
        (
            thread.cursor.clone(),
            thread
                .entities
                .iter()
                .map(|e| (e.id.clone(), (e.run, e.fields["n"].as_i64().unwrap())))
                .collect(),
        )
    })
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 64, .. ProptestConfig::default() })]

    #[test]
    fn the_cache_keeps_what_its_model_says(ops in prop::collection::vec(op(), 1..40)) {
        let dir = tempfile::tempdir().unwrap();
        let mut cache = LocalCache::open(Some(dir.path()));
        let mut model = Model::default();
        for op in ops {
            match op {
                Op::Snapshot { key, offset, put } => {
                    let cursor = Cursor { handle: "log".into(), offset, floor: None };
                    let mut kept = Entities::new();
                    for &(id, run, n) in &put { kept.insert(IDS[id].into(), (run, n)); }
                    model.threads.insert(KEYS[key].into(), (cursor.clone(), kept));
                    cache.store_thread(ThreadUpdate { key: KEYS[key].into(), cursor, replace: true, put: to_entities(&put), gone: vec![] });
                }
                Op::Change { key, offset, put, gone } => {
                    let cursor = Cursor { handle: "log".into(), offset, floor: None };
                    if let Some((at, kept)) = model.threads.get_mut(KEYS[key]) {
                        *at = cursor.clone();
                        for &id in &gone { kept.remove(IDS[id]); }
                        for &(id, run, n) in &put { kept.insert(IDS[id].into(), (run, n)); }
                    }
                    cache.store_thread(ThreadUpdate {
                        key: KEYS[key].into(), cursor, replace: false, put: to_entities(&put),
                        gone: gone.iter().map(|&id| ("item".to_owned(), IDS[id].to_owned())).collect(),
                    });
                }
                Op::Trim { key, floor } => {
                    if let Some((at, kept)) = model.threads.get_mut(KEYS[key])
                        && at.floor.is_none_or(|f| f < floor)
                    {
                        at.floor = Some(floor);
                        kept.retain(|_, (run, _)| run.is_none_or(|r| r >= floor));
                    }
                    cache.trim_thread(KEYS[key], floor);
                }
                Op::Forget { key } => {
                    model.threads.remove(KEYS[key]);
                    cache.forget_thread(KEYS[key]);
                }
                Op::ForgetEnvironment { env } => {
                    let prefix = format!("{}:", ENVS[env]);
                    model.threads.retain(|key, _| !key.starts_with(&prefix));
                    cache.forget_environment(ENVS[env]);
                }
                Op::Load { key } => {
                    prop_assert_eq!(seen(&load(&cache, KEYS[key])), model.threads.get(KEYS[key]).cloned());
                }
                Op::StoreShell { origin, mc, removed, reset, rev, put, gone } => {
                    let mcs = model.shells.entry(ORIGINS[origin].into()).or_default();
                    if removed {
                        mcs.remove(MCS[mc]);
                    } else if reset || mcs.contains_key(MCS[mc]) {
                        let entry = mcs.entry(MCS[mc].into()).or_default();
                        if reset { entry.1.clear(); }
                        entry.0 = rev;
                        for &id in &gone { entry.1.remove(IDS[id]); }
                        for &(id, n) in &put { entry.1.insert(IDS[id].into(), n); }
                    }
                    cache.store_shell(ORIGINS[origin], vec![ShellMcUpdate {
                        mc: MCS[mc].into(), removed, reset, epoch: "e".into(), rev,
                        environment: Map::new(),
                        put: put.iter().map(|&(id, n)| ShellRow { id: IDS[id].into(), kind: "thread".into(), fields: fields(n) }).collect(),
                        gone: gone.iter().map(|&id| IDS[id].to_owned()).collect(),
                    }]);
                }
                Op::ReadShell { origin } => {
                    let read = Rc::new(RefCell::new(None));
                    let slot = read.clone();
                    cache.shell(origin.map_or("", |o| ORIGINS[o]), move |s| *slot.borrow_mut() = Some(s));
                    cache.drain();
                    let shell: Shell = read.borrow_mut().take().expect("drain runs the reply");
                    let read: Mcs = shell.mcs.iter().map(|mc| (
                        mc.mc.clone(),
                        (mc.rev, mc.rows.iter().map(|r| (r.id.clone(), r.fields["n"].as_i64().unwrap())).collect()),
                    )).collect();
                    match origin {
                        Some(o) => {
                            // Only the origin read stays.
                            model.shells.retain(|kept, _| kept == ORIGINS[o]);
                            let expected = model.shells.get(ORIGINS[o]).cloned().unwrap_or_default();
                            prop_assert_eq!(read, expected);
                        }
                        None => {
                            // Some kept origin, whole, or none at all.
                            if shell.origin.is_empty() {
                                prop_assert!(model.shells.values().all(|mcs| mcs.is_empty()));
                            } else {
                                prop_assert_eq!(Some(&read), model.shells.get(&shell.origin));
                            }
                        }
                    }
                }
                Op::Reopen => {
                    drop(cache);
                    cache = LocalCache::open(Some(dir.path()));
                }
            }
        }
    }
}
