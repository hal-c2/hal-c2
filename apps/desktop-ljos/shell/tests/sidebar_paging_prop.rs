//! The settled shelf's paging, against any order of "Show more", threads
//! that settle and go, threads a plugin started, the MC's
//! `sidebarShowSettledPluginThreads` flipped by another client, and opens:
//! the shelf lists the settled threads (the plugin's only while the setting
//! says so, or while one is open) newest first, a page at a time, the open
//! thread past the page, and counts every one it could list.

mod common;
#[path = "support/scripted_mc.rs"]
mod scripted_mc;

use std::cell::Cell;
use std::collections::BTreeMap;
use std::rc::Rc;

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controller;
use hal_c2_shell::controllers::sidebar::{self, Sidebar};
use hal_c2_shell::json::Json;
use hal_c2_shell::{Launch, start};
use ljos::App;
use ljos::prelude::Engine;
use proptest::prelude::*;
use scripted_mc::ScriptedMc;
use serde_json::json;

const AT: &str = "2026-09-23T09:00:00Z";
const THREADS: usize = 7;
/// One page is two rows, so a handful of settled threads already page.
const PAGE: usize = 2;

#[derive(Clone, Debug)]
enum Op {
    /// The thread settles (or is replaced by a settled one), started by a
    /// plugin or not.
    Put(usize, bool),
    Remove(usize),
    More,
    /// Another client turns the setting on or off.
    Plugins(bool),
    Open(usize),
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        4 => ((0..THREADS), any::<bool>()).prop_map(|(i, plugin)| Op::Put(i, plugin)),
        1 => (0..THREADS).prop_map(Op::Remove),
        3 => Just(Op::More),
        2 => any::<bool>().prop_map(Op::Plugins),
        2 => (0..THREADS).prop_map(Op::Open),
    ]
}

#[derive(Default)]
struct Model {
    /// The settled threads: whether a plugin started each.
    settled: BTreeMap<usize, bool>,
    shown: usize,
    plugins: bool,
    open: Option<usize>,
}

impl Model {
    /// The keys the shelf could list, newest settled first (a greater index
    /// settled later).
    fn listed(&self) -> Vec<usize> {
        self.settled
            .iter()
            .rev()
            .filter(|&(&i, &plugin)| self.plugins || !plugin || self.open == Some(i))
            .map(|(&i, _)| i)
            .collect()
    }

    /// The rows the shelf lists: a page at a time, the open thread past it.
    fn rows(&self) -> Vec<usize> {
        self.listed()
            .into_iter()
            .enumerate()
            .filter(|&(place, i)| place < self.shown || self.open == Some(i))
            .map(|(_, i)| i)
            .collect()
    }
}

fn key(i: usize) -> String {
    format!("env-a:t{i}")
}

fn thread_row(i: usize, plugin: bool) -> Json {
    let mut row = json!({
        "id": format!("t{i}"), "projectId": "p1", "title": format!("t{i}"),
        "createdAt": AT, "updatedAt": AT,
        "settledOverride": "settled", "settledAt": format!("2026-09-23T08:{:02}:00Z", 10 + i),
    });
    row["plugin"] = if plugin {
        json!({"id": "code-review", "kind": "review", "listed": true})
    } else {
        Json::Null
    };
    row
}

struct Rig {
    engine: Engine,
    mc: Rc<ScriptedMc>,
    plugins: Rc<Cell<bool>>,
    shell: Json,
    config: Json,
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
        let plugins = Rc::new(Cell::new(false));
        let document = plugins.clone();
        let mc = ScriptedMc::new(move |_, method, _| {
            Ok(if method == "hal-c2.readSettings" {
                json!({"settings": {"sidebarShowSettledPluginThreads": document.get()}, "version": 1})
            } else {
                json!({})
            })
        });
        *mc.environment.borrow_mut() = "env-a".into();
        let launch = Launch {
            mc_origin: Some("http://127.0.0.1:3773".into()),
            cache_dir: Some(dir.path().to_owned()),
            ..Launch::default()
        };
        start(&engine, &launch, mc.clone());
        let find = |kind: &str| {
            mc.subscribed()
                .into_iter()
                .find(|s| s["type"] == kind)
                .unwrap_or_else(|| panic!("the {kind} shape"))
        };
        let shell = find("shell");
        mc.send(
            &engine,
            &shell,
            json!({
                "t": "shell",
                "mcs": [{"mc": "mc-a", "environment": {"environmentId": "env-a",
                    "capabilities": {"threadSettlement": true}}, "online": true, "epoch": "e1", "rev": 1}],
                "rows": [["mc-a", "p1", "project",
                    {"id": "p1", "title": "Ljos", "workspaceRoot": "/w/ljos", "createdAt": AT, "updatedAt": AT}]],
            }),
        );
        // The controllers follow the MC once it has sent its first snapshot.
        let config = find("config");
        mc.send(&engine, &config, json!({"t": "config", "config": {}}));
        mc.deliver(&engine);
        controller::with::<Sidebar, _>(&engine, |s, e| {
            s.set_settled_page(PAGE);
            s.refresh(e);
        })
        .expect("the sidebar");
        Rig {
            engine,
            mc,
            plugins,
            shell,
            config,
            _dir: dir,
        }
    }

    fn rows(&self, rows: Vec<Json>) {
        self.mc.send(
            &self.engine,
            &self.shell,
            json!({"t": "shell.rows", "mc": "mc-a", "rows": rows}),
        );
    }

    fn set_plugins(&self, on: bool) {
        self.plugins.set(on);
        self.mc.send(
            &self.engine,
            &self.config,
            json!({"t": "config.settings",
                "settings": {"sidebarShowSettledPluginThreads": on}}),
        );
        self.mc.deliver(&self.engine);
    }

    fn view(&self) -> Json {
        Bridge::of(&self.engine)
            .published(&self.engine, "sidebar")
            .unwrap()
    }
}

fn run(ops: &[Op]) {
    let rig = Rig::new();
    let mut model = Model {
        shown: PAGE,
        ..Model::default()
    };
    for op in ops {
        match *op {
            Op::Put(i, plugin) => {
                rig.rows(vec![json!([
                    format!("t{i}"),
                    "thread",
                    thread_row(i, plugin)
                ])]);
                model.settled.insert(i, plugin);
            }
            Op::Remove(i) => {
                // The window leaves a thread that goes; the model does not follow.
                if model.open == Some(i) {
                    continue;
                }
                let gone = json!({"id": format!("t{i}"), "deletedAt": AT});
                rig.rows(vec![json!([format!("t{i}"), "thread", gone])]);
                model.settled.remove(&i);
            }
            Op::More => {
                Bridge::of(&rig.engine).dispatch(&rig.engine, "sidebar.more", json!({}));
                model.shown += PAGE;
            }
            Op::Plugins(on) => {
                rig.set_plugins(on);
                model.plugins = on;
            }
            Op::Open(i) => {
                if !model.settled.contains_key(&i) {
                    continue;
                }
                Bridge::of(&rig.engine).dispatch(
                    &rig.engine,
                    "thread.open",
                    json!({"key": key(i)}),
                );
                model.open = Some(i);
            }
        }
        let view = rig.view();
        let shelf: Vec<String> = view["settled"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["key"].as_str().unwrap().to_owned())
            .collect();
        let rows: Vec<String> = model.rows().into_iter().map(key).collect();
        assert_eq!(shelf, rows, "the shelf after {op:?}");
        assert_eq!(
            view["settledTotal"],
            model.listed().len(),
            "the count after {op:?}"
        );
        assert_eq!(view["settledPage"], PAGE, "the page after {op:?}");
        let listed: Vec<String> = model.listed().into_iter().map(key).collect();
        assert_eq!(sidebar::ordered_keys(&rig.engine), listed, "after {op:?}");
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(48))]

    #[test]
    fn the_shelf_pages_and_hides_plugin_threads_as_the_model_says(ops in proptest::collection::vec(op(), 1..40)) {
        run(&ops);
    }
}
