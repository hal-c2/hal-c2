//! The store with a saved environment's link beside the shell's own client
//! (desktop-qt's ShellStore::addLink), in any order of either client's
//! snapshots, a link's refusal, and the link coming and going: each client's
//! snapshot speaks only for the MCs it listed, a link's refusal is never the
//! shell's problem, and the route goes to the link that serves an
//! environment.

use hal_c2_shell::mc::Frame;
use hal_c2_shell::store::{Client, ShellStore};
use proptest::prelude::*;
use serde_json::{Value, json};

const AT: &str = "2026-09-23T09:00:00Z";
const THREADS: &[&str] = &["t1", "t2", "t3"];

#[derive(Clone, Debug)]
enum Op {
    /// The shell's own snapshot: env-a's MC with the threads of the mask, or
    /// no MC at all.
    Own(Option<u8>),
    /// Studio's link's snapshot, while linked.
    Link(Option<u8>),
    /// Studio refuses its link.
    LinkError,
    AddLink,
    RemoveLink {
        forget: bool,
    },
}

fn op() -> impl Strategy<Value = Op> {
    let mask = prop::option::weighted(0.8, 0u8..8);
    prop_oneof![
        3 => mask.clone().prop_map(Op::Own),
        3 => mask.prop_map(Op::Link),
        1 => Just(Op::LinkError),
        2 => Just(Op::AddLink),
        2 => any::<bool>().prop_map(|forget| Op::RemoveLink { forget }),
    ]
}

fn threads(mask: u8) -> Vec<&'static str> {
    THREADS
        .iter()
        .enumerate()
        .filter(|(i, _)| mask & (1 << i) != 0)
        .map(|(_, t)| *t)
        .collect()
}

fn snapshot(mc: &str, environment: &str, mask: Option<u8>, rev: i64) -> Frame {
    let (mcs, rows): (Vec<Value>, Vec<Value>) = match mask {
        None => (Vec::new(), Vec::new()),
        Some(mask) => (
            vec![json!({"mc": mc, "online": true, "epoch": "e1", "rev": rev,
                        "environment": {"environmentId": environment, "label": environment}})],
            threads(mask)
                .into_iter()
                .map(|t| {
                    json!([mc, t, "thread",
                           {"id": t, "projectId": "p1", "title": t, "createdAt": AT, "updatedAt": AT}])
                })
                .collect(),
        ),
    };
    json!({"t": "shell", "mcs": mcs, "rows": rows})
        .as_object()
        .cloned()
        .unwrap()
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Owner {
    Own,
    Link,
    Nobody,
}

/// What the store should hold.
#[derive(Debug, Default)]
struct Model {
    own: Option<u8>,
    studio: Option<(u8, Owner)>,
    linked: bool,
    snapshots: u64,
}

impl Model {
    /// Whether `client`'s snapshot speaks for studio's MC (answers_for).
    fn speaks_for_studio(&self, client: Owner) -> bool {
        match self.studio {
            Some((_, Owner::Nobody)) if self.linked => client == Owner::Link,
            Some((_, Owner::Nobody)) => client == Owner::Own,
            Some((_, owner)) => owner == client,
            None => false,
        }
    }

    fn keys(&self) -> Vec<String> {
        let mut keys: Vec<String> = self
            .own
            .map(threads)
            .unwrap_or_default()
            .into_iter()
            .map(|t| format!("env-a:{t}"))
            .chain(
                self.studio
                    .map(|(mask, _)| threads(mask))
                    .unwrap_or_default()
                    .into_iter()
                    .map(|t| format!("studio:{t}")),
            )
            .collect();
        keys.sort();
        keys
    }

    fn link_serving(&self) -> Option<String> {
        match self.studio {
            Some((_, Owner::Link)) => Some("studio".into()),
            Some(_) => None,
            None => self.linked.then(|| "studio".into()),
        }
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(256))]

    #[test]
    fn each_client_speaks_for_its_own(ops in prop::collection::vec(op(), 1..40)) {
        let mut store = ShellStore::default();
        let mut model = Model::default();
        let studio = Client::Link("studio".into());
        for (rev, op) in ops.iter().enumerate() {
            let rev = rev as i64 + 1;
            match *op {
                Op::Own(mask) => {
                    store.apply(&snapshot("mc-a", "env-a", mask, rev));
                    model.own = mask;
                    if model.speaks_for_studio(Owner::Own) {
                        model.studio = None;
                    }
                    model.snapshots += 1;
                }
                Op::Link(mask) => {
                    if !model.linked {
                        continue;
                    }
                    store.apply_from(&snapshot("mc-s", "studio", mask, rev), &studio);
                    match mask {
                        Some(mask) => model.studio = Some((mask, Owner::Link)),
                        None if model.speaks_for_studio(Owner::Link) => model.studio = None,
                        None => {}
                    }
                }
                Op::LinkError => {
                    let refusal = json!({"t": "error", "reason": "refused"});
                    prop_assert!(!store.apply_from(refusal.as_object().unwrap(), &studio));
                }
                Op::AddLink => {
                    prop_assert_eq!(store.add_link("studio"), !model.linked);
                    model.linked = true;
                }
                Op::RemoveLink { forget } => {
                    store.remove_link("studio", forget);
                    if model.linked {
                        model.linked = false;
                        if let Some((mask, Owner::Link | Owner::Nobody)) = model.studio {
                            model.studio = (!forget).then_some((mask, Owner::Nobody));
                        }
                    }
                }
            }
            prop_assert_eq!(store.threads().iter().map(|t| t.key()).collect::<std::collections::BTreeSet<_>>(),
                            model.keys().into_iter().collect::<std::collections::BTreeSet<_>>(),
                            "after {:?}", op);
            prop_assert_eq!(store.link_serving("studio"), model.link_serving(), "after {:?}", op);
            prop_assert_eq!(store.link_serving("env-a"), None);
            prop_assert_eq!(store.link_of("mc-a"), None);
            prop_assert!(store.problem().is_empty());
            prop_assert_eq!(store.snapshots(), model.snapshots);
            prop_assert_eq!(store.links().contains("studio"), model.linked);
        }
    }
}
