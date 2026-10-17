//! The sidebar's selection and its parking of threads, against any order of
//! clicks, opens, settles and MC answers: the published selection is the
//! rows chosen (one by one, or the run from the anchor), in the order they
//! render, and a thread is settled once however often it is asked while the
//! MC has not answered.

mod common;
#[path = "support/scripted_mc.rs"]
mod scripted_mc;

use std::cell::Cell;
use std::collections::BTreeSet;
use std::rc::Rc;

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controller;
use hal_c2_shell::controllers::sidebar::Sidebar;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::McError;
use hal_c2_shell::{Launch, start};
use ljos::App;
use ljos::prelude::Engine;
use proptest::prelude::*;
use scripted_mc::ScriptedMc;
use serde_json::json;

const AT: &str = "2026-09-23T09:00:00Z";
const THREADS: usize = 4;

#[derive(Clone, Debug)]
enum Op {
    Toggle(usize),
    Range(usize),
    Clear,
    Open(usize),
    Settle(usize),
    /// The MC answers every command out, or refuses them all.
    Answer(bool),
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        3 => (0..THREADS).prop_map(Op::Toggle),
        2 => (0..THREADS).prop_map(Op::Range),
        1 => Just(Op::Clear),
        1 => (0..THREADS).prop_map(Op::Open),
        2 => (0..THREADS).prop_map(Op::Settle),
        2 => any::<bool>().prop_map(Op::Answer),
    ]
}

#[derive(Default)]
struct Model {
    selected: BTreeSet<usize>,
    anchor: Option<usize>,
    pending: BTreeSet<usize>,
    settles: usize,
}

struct Rig {
    engine: Engine,
    mc: Rc<ScriptedMc>,
    accept: Rc<Cell<bool>>,
    /// The thread keys in the order the sidebar renders them.
    order: Vec<String>,
    _dir: tempfile::TempDir,
}

impl Rig {
    fn new() -> Rig {
        let dir = tempfile::tempdir().unwrap();
        let source = common::compile(&[("Main", "import QtQuick\nItem {}\n")], &[]);
        let engine = App::new("test")
            .register(hal_c2_shell::register)
            .source(source)
            .build_engine();
        engine.set_wall_clock_origin(Some(1_790_000_000_000.0));
        let accept = Rc::new(Cell::new(true));
        let answer = accept.clone();
        let mc = ScriptedMc::new(move |_, _, _| {
            if answer.get() {
                Ok(json!({}))
            } else {
                Err(McError::new("refused"))
            }
        });
        *mc.environment.borrow_mut() = "env-a".into();
        let launch = Launch {
            mc_origin: Some("http://127.0.0.1:3773".into()),
            cache_dir: Some(dir.path().to_owned()),
            ..Launch::default()
        };
        start(&engine, &launch, mc.clone());
        let mut rows = vec![json!(["mc-a", "p1", "project",
            {"id": "p1", "title": "Ljos", "workspaceRoot": "/w/ljos", "createdAt": AT, "updatedAt": AT}])];
        for i in 0..THREADS {
            let id = format!("t{i}");
            rows.push(json!(["mc-a", id, "thread",
                {"id": id, "projectId": "p1", "title": id, "createdAt": AT, "updatedAt": AT}]));
        }
        let shape = mc
            .subscribed()
            .into_iter()
            .find(|s| s["type"] == "shell")
            .expect("the shell shape");
        mc.send(
            &engine,
            &shape,
            json!({
                "t": "shell",
                "mcs": [{"mc": "mc-a", "environment": {"environmentId": "env-a",
                    "capabilities": {"threadSettlement": true}}, "online": true, "epoch": "e1", "rev": 1}],
                "rows": rows,
            }),
        );
        let order = Bridge::of(&engine).published(&engine, "sidebar").unwrap()["active"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["key"].as_str().unwrap().to_owned())
            .collect::<Vec<_>>();
        assert_eq!(order.len(), THREADS);
        Rig {
            engine,
            mc,
            accept,
            order,
            _dir: dir,
        }
    }

    fn dispatch(&self, action: &str, payload: Json) {
        Bridge::of(&self.engine).dispatch(&self.engine, action, payload);
    }

    fn selected(&self) -> Vec<String> {
        serde_json::from_value(
            Bridge::of(&self.engine)
                .published(&self.engine, "sidebar")
                .unwrap()["selectedKeys"]
                .clone(),
        )
        .unwrap()
    }

    fn parking(&self, key: &str) -> bool {
        controller::with::<Sidebar, _>(&self.engine, |s, _| s.parking(key)).unwrap()
    }
}

fn run(ops: &[Op]) {
    let rig = Rig::new();
    let mut model = Model::default();
    for op in ops {
        match *op {
            Op::Toggle(i) => {
                rig.dispatch("thread.select.toggle", json!({"key": rig.order[i]}));
                if !model.selected.remove(&i) {
                    model.selected.insert(i);
                    model.anchor = Some(i);
                }
            }
            Op::Range(i) => {
                rig.dispatch("thread.select.range", json!({"key": rig.order[i]}));
                match model.anchor {
                    Some(a) => model.selected.extend(a.min(i)..=a.max(i)),
                    None => {
                        model.selected.insert(i);
                        model.anchor = Some(i);
                    }
                }
            }
            Op::Clear => {
                rig.dispatch("thread.select.clear", json!({}));
                model.selected.clear();
            }
            Op::Open(i) => {
                rig.dispatch("thread.open", json!({"key": rig.order[i]}));
                model.selected.clear();
                model.anchor = Some(i);
            }
            Op::Settle(i) => {
                rig.dispatch("thread.settle", json!({"key": rig.order[i]}));
                if model.pending.insert(i) {
                    model.settles += 1;
                }
            }
            Op::Answer(ok) => {
                rig.accept.set(ok);
                rig.mc.deliver(&rig.engine);
                model.pending.clear();
            }
        }
        let expected: Vec<String> = model
            .selected
            .iter()
            .map(|i| rig.order[*i].clone())
            .collect();
        assert_eq!(rig.selected(), expected, "after {op:?}");
        assert_eq!(
            rig.mc
                .payloads("orchestration.dispatchCommand")
                .iter()
                .filter(|c| c["type"] == "thread.settle")
                .count(),
            model.settles,
            "after {op:?}"
        );
        for (i, key) in rig.order.iter().enumerate() {
            assert_eq!(
                rig.parking(key),
                model.pending.contains(&i),
                "{key} after {op:?}"
            );
        }
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(32))]

    #[test]
    fn selection_and_parking_follow_the_model(ops in proptest::collection::vec(op(), 1..40)) {
        run(&ops);
    }
}
