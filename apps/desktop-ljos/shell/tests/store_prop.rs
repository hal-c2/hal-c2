//! The store against an MC that sends what a real one does: any order of row
//! changes, machines going offline, leaving and joining, lost connections,
//! restarts and MCs that forget their history leaves the store holding the
//! cluster as the MC has it once it answers, resuming from what it kept.

use std::collections::BTreeMap;
use std::path::Path;
use std::rc::Rc;

use hal_c2_shell::cache::LocalCache;
use hal_c2_shell::mc::Frame;
use hal_c2_shell::store::{Changes, ShellStore};
use proptest::prelude::*;
use serde_json::{Value, json};

const ORIGIN: &str = "http://127.0.0.1:3773";
const MCS: &[&str] = &["mc-a", "mc-b"];
const IDS: &[&str] = &["a", "b", "c"];
const KINDS: &[&str] = &["thread", "project"];
const AT: &str = "2026-09-23T09:00:00Z";

#[derive(Clone, Debug)]
enum Op {
    Put {
        mc: usize,
        kind: usize,
        id: usize,
        n: i64,
    },
    Delete {
        mc: usize,
        kind: usize,
        id: usize,
    },
    Online {
        mc: usize,
        online: bool,
    },
    Leave {
        mc: usize,
    },
    Join {
        mc: usize,
    },
    /// The MC lost its history: a new epoch, every row anew.
    Forget {
        mc: usize,
    },
    Disconnect,
    Reconnect,
    Flush,
    Restart,
    /// A start whose MC answers before the cache has said what it kept.
    RestartLate,
}

fn op() -> impl Strategy<Value = Op> {
    let mc = 0..MCS.len();
    prop_oneof![
        4 => (mc.clone(), 0..KINDS.len(), 0..IDS.len(), 0i64..100)
            .prop_map(|(mc, kind, id, n)| Op::Put { mc, kind, id, n }),
        2 => (mc.clone(), 0..KINDS.len(), 0..IDS.len()).prop_map(|(mc, kind, id)| Op::Delete { mc, kind, id }),
        1 => (mc.clone(), any::<bool>()).prop_map(|(mc, online)| Op::Online { mc, online }),
        1 => mc.clone().prop_map(|mc| Op::Leave { mc }),
        1 => mc.clone().prop_map(|mc| Op::Join { mc }),
        1 => mc.prop_map(|mc| Op::Forget { mc }),
        1 => Just(Op::Disconnect),
        2 => Just(Op::Reconnect),
        1 => Just(Op::Flush),
        1 => Just(Op::Restart),
        1 => Just(Op::RestartLate),
    ]
}

/// One machine as its MC keeps it: every row with the revision that last
/// changed it, the deleted ones as tombstones.
#[derive(Clone, Debug)]
struct Machine {
    listed: bool,
    online: bool,
    epoch: u32,
    rev: i64,
    rows: BTreeMap<(usize, usize), (Option<i64>, i64)>,
}

fn environment(mc: usize) -> Value {
    json!({"environmentId": format!("env-{mc}"), "capabilities": {}})
}

fn fields(kind: usize, id: usize, n: Option<i64>) -> Value {
    match n {
        None => json!({"id": row_id(kind, id), "deletedAt": AT}),
        Some(n) if KINDS[kind] == "thread" => json!({
            "id": row_id(kind, id), "projectId": "p", "title": n.to_string(), "createdAt": AT, "updatedAt": AT,
        }),
        Some(n) => json!({
            "id": row_id(kind, id), "title": n.to_string(), "workspaceRoot": "/w", "createdAt": AT, "updatedAt": AT,
        }),
    }
}

impl Machine {
    fn epoch(&self) -> String {
        format!("epoch-{}", self.epoch)
    }

    fn change(&mut self, kind: usize, id: usize, n: Option<i64>) -> Frame {
        self.rev += 1;
        self.rows.insert((kind, id), (n, self.rev));
        frame(json!({
            "t": "shell.rows", "mc": "", "epoch": self.epoch(), "rev": self.rev,
            "rows": [[row_id(kind, id), KINDS[kind], fields(kind, id, n)]],
        }))
    }

    /// The rows a client holding `have` lacks, and whether they replace all.
    fn since(&self, have: Option<(&str, i64)>) -> (bool, Vec<(usize, usize, Option<i64>)>) {
        let delta = have.filter(|(epoch, rev)| *epoch == self.epoch() && *rev <= self.rev);
        let rows = self
            .rows
            .iter()
            .filter(|(_, (n, at))| match delta {
                Some((_, rev)) => *at > rev,
                None => n.is_some(),
            })
            .map(|(&(kind, id), &(n, _))| (kind, id, n))
            .collect();
        (delta.is_none(), rows)
    }
}

/// The MC's ids are one namespace per machine (UUIDs): a thread and a
/// project never share one, and `gone` and the cache key rows by id alone.
fn row_id(kind: usize, id: usize) -> String {
    format!("{}{}", &KINDS[kind][..1], IDS[id])
}

fn frame(value: Value) -> Frame {
    value.as_object().cloned().unwrap()
}

fn with_mc(mut frame: Frame, mc: usize) -> Frame {
    frame.insert("mc".into(), MCS[mc].into());
    frame
}

/// The `shell` frame the MC answers a subscription carrying `have` with.
fn snapshot(machines: &[Machine], have: &Value) -> Frame {
    let mut mcs = Vec::new();
    let mut rows = Vec::new();
    for (index, machine) in machines.iter().enumerate().filter(|(_, m)| m.listed) {
        let held = have[MCS[index]]
            .as_array()
            .map(|v| (v[0].as_str().unwrap_or(""), v[1].as_i64().unwrap_or(-1)));
        let (reset, changed) = machine.since(held);
        mcs.push(json!({
            "mc": MCS[index], "environment": environment(index), "online": machine.online,
            "reset": reset, "epoch": machine.epoch(), "rev": machine.rev,
        }));
        for (kind, id, n) in changed {
            rows.push(json!([
                MCS[index],
                row_id(kind, id),
                KINDS[kind],
                fields(kind, id, n)
            ]));
        }
    }
    frame(json!({"t": "shell", "mcs": mcs, "rows": rows}))
}

/// A store opened at the MC, before the cache has said what it kept: that
/// comes in later, as the shell's loop delivers it.
fn opening(dir: &Path) -> (ShellStore, Rc<LocalCache>) {
    let cache = Rc::new(LocalCache::open(Some(dir)));
    let mut store = ShellStore::new(Some(cache.clone()));
    store.open(ORIGIN);
    (store, cache)
}

fn open(dir: &Path) -> ShellStore {
    let (mut store, cache) = opening(dir);
    cache.drain();
    store.take_kept();
    store
}

/// The store holds the cluster as the MC has it.
fn agrees(store: &ShellStore, machines: &[Machine]) -> Result<(), TestCaseError> {
    let mut threads = 0;
    let mut projects = 0;
    let listed: Vec<_> = machines
        .iter()
        .enumerate()
        .filter(|(_, m)| m.listed)
        .collect();
    prop_assert_eq!(store.environments().len(), listed.len());
    for (index, machine) in listed {
        let env = format!("env-{index}");
        prop_assert_eq!(store.mc_serving(&env), MCS[index]);
        prop_assert_eq!(store.environment_online(&env), machine.online);
        for (&(kind, id), &(n, _)) in &machine.rows {
            let row = match KINDS[kind] {
                "thread" => store.thread_row(&format!("{env}:{}", row_id(kind, id))),
                _ => store.project_row(&env, &row_id(kind, id)),
            };
            let title = row.and_then(|r| r["title"].as_str()).map(str::to_owned);
            prop_assert_eq!(
                title,
                n.map(|n| n.to_string()),
                "{} {} {}",
                env,
                KINDS[kind],
                row_id(kind, id)
            );
            if n.is_some() {
                *(if KINDS[kind] == "thread" {
                    &mut threads
                } else {
                    &mut projects
                }) += 1;
            }
        }
    }
    prop_assert_eq!(store.threads().len(), threads);
    prop_assert_eq!(store.projects().len(), projects);
    Ok(())
}

/// Every row the store holds, by key.
fn summary(store: &ShellStore) -> Vec<(String, String)> {
    let mut rows: Vec<(String, String)> = store
        .threads()
        .into_iter()
        .map(|t| (t.key(), t.title))
        .chain(
            store
                .projects()
                .into_iter()
                .map(|p| (format!("project {}", p.key()), p.title)),
        )
        .collect();
    rows.sort();
    rows
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 128, .. ProptestConfig::default() })]

    #[test]
    fn the_store_holds_the_cluster_the_mc_has(ops in prop::collection::vec(op(), 1..50)) {
        let dir = tempfile::tempdir().unwrap();
        let mut machines = vec![
            Machine { listed: true, online: true, epoch: 0, rev: 0, rows: BTreeMap::new() };
            MCS.len()
        ];
        let mut store = open(dir.path());
        let mut connected = true;
        store.apply(&snapshot(&machines, &store.have()));
        let mut epochs = 0;
        for op in ops {
            // What the MC sends now, if anything reaches the store.
            let sent: Vec<Frame> = match op {
                Op::Put { mc, kind, id, n } => {
                    let change = machines[mc].change(kind, id, Some(n));
                    if machines[mc].listed { vec![with_mc(change, mc)] } else { vec![] }
                }
                Op::Delete { mc, kind, id } => {
                    let change = machines[mc].change(kind, id, None);
                    if machines[mc].listed { vec![with_mc(change, mc)] } else { vec![] }
                }
                Op::Online { mc, online } => {
                    machines[mc].online = online;
                    if machines[mc].listed {
                        vec![frame(json!({"t": "shell.mc", "mc": MCS[mc], "online": online}))]
                    } else {
                        vec![]
                    }
                }
                Op::Leave { mc } if machines[mc].listed => {
                    machines[mc].listed = false;
                    vec![frame(json!({"t": "shell.mc", "mc": MCS[mc], "removed": true}))]
                }
                Op::Join { mc } if !machines[mc].listed => {
                    let machine = &mut machines[mc];
                    machine.listed = true;
                    let (_, rows) = machine.since(None);
                    vec![
                        frame(json!({"t": "shell.environment", "mc": MCS[mc], "environment": environment(mc)})),
                        frame(json!({"t": "shell.mc", "mc": MCS[mc], "online": machine.online})),
                        frame(json!({
                            "t": "shell.rows", "mc": MCS[mc], "reset": true,
                            "epoch": machine.epoch(), "rev": machine.rev,
                            "rows": rows.iter().map(|&(kind, id, n)| json!([row_id(kind, id), KINDS[kind], fields(kind, id, n)])).collect::<Vec<_>>(),
                        })),
                    ]
                }
                Op::Leave { .. } | Op::Join { .. } => vec![],
                Op::Forget { mc } => {
                    // A restarted MC: its subscribers resubscribe.
                    epochs += 1;
                    let machine = &mut machines[mc];
                    machine.epoch = epochs;
                    machine.rows.retain(|_, (n, _)| n.is_some());
                    if connected { vec![snapshot(&machines, &store.have())] } else { vec![] }
                }
                Op::Disconnect => {
                    connected = false;
                    vec![]
                }
                Op::Reconnect => {
                    connected = true;
                    vec![snapshot(&machines, &store.have())]
                }
                Op::Flush => {
                    store.flush();
                    vec![]
                }
                Op::Restart => {
                    // What it held is what the next start shows, until the
                    // MC answers.
                    let held = summary(&store);
                    drop(store);
                    store = open(dir.path());
                    connected = false;
                    prop_assert_eq!(summary(&store), held);
                    prop_assert!(!store.synchronized());
                    vec![]
                }
                Op::RestartLate => {
                    drop(store);
                    let cache;
                    (store, cache) = opening(dir.path());
                    connected = true;
                    store.apply(&snapshot(&machines, &store.have()));
                    // Too late: the MC's rows stand.
                    cache.drain();
                    prop_assert_eq!(store.take_kept(), Changes::default());
                    vec![]
                }
            };
            if connected {
                for frame in &sent {
                    store.apply(frame);
                }
                prop_assert!(store.synchronized());
                agrees(&store, &machines)?;
            }
        }
        if !connected {
            store.apply(&snapshot(&machines, &store.have()));
            agrees(&store, &machines)?;
        }
    }
}
