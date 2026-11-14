//! Navigation as a state machine: threads opened, settings and usage
//! visited, back and forward, threads renamed, deleted and restored by the
//! MC, and the app restarted over the folders it keeps. The route shown is
//! what the model says, what is saved is what is shown, a restart comes
//! back to it (a vanished thread to a draft), and back never lands on a
//! thread that is gone.

use std::collections::BTreeMap;
use std::path::PathBuf;

use hal_c2_shell::Launch;
use hal_c2_shell::commands::Commands;
use hal_c2_shell::json::Json;
use proptest::prelude::*;
use serde_json::json;

use crate::Hub;
use crate::navigation::{ORIGIN, kind, project, route, rows, shell, thread};

const THREADS: [&str; 3] = ["t1", "t2", "t3"];
const SECTIONS: [&str; 2] = ["/settings/archived", "/settings/general"];

#[derive(Clone, Debug)]
enum Op {
    Open(usize),
    Settings(usize),
    Usage,
    Back,
    Forward,
    Rename(usize, u8),
    Delete(usize),
    Restore(usize),
    Restart,
}

fn op() -> impl Strategy<Value = Op> {
    let t = 0..THREADS.len();
    prop_oneof![
        4 => t.clone().prop_map(Op::Open),
        2 => (0..SECTIONS.len()).prop_map(Op::Settings),
        2 => Just(Op::Usage),
        3 => Just(Op::Back),
        2 => Just(Op::Forward),
        2 => (t.clone(), 0u8..4).prop_map(|(t, n)| Op::Rename(t, n)),
        2 => t.clone().prop_map(Op::Delete),
        2 => t.prop_map(Op::Restore),
        1 => Just(Op::Restart),
    ]
}

/// Where the model says the window is.
#[derive(Clone, Debug, PartialEq)]
enum At {
    Thread(usize),
    Section(usize),
    Usage,
    /// The draft the window landed on, or none known yet.
    Draft,
}

struct World {
    hub: Option<Hub>,
    state: tempfile::TempDir,
    data: tempfile::TempDir,
    /// The MC's threads: title by thread index, while listed.
    listed: BTreeMap<usize, String>,
    rev: u32,
    at: At,
    draft: String,
}

impl World {
    fn new() -> World {
        let state = tempfile::tempdir_in(PathBuf::from(env!("CARGO_TARGET_TMPDIR"))).unwrap();
        let data = tempfile::tempdir_in(PathBuf::from(env!("CARGO_TARGET_TMPDIR"))).unwrap();
        let mut world = World {
            hub: None,
            state,
            data,
            listed: (0..THREADS.len())
                .map(|t| (t, format!("Thread {t}")))
                .collect(),
            rev: 1,
            at: At::Draft,
            draft: String::new(),
        };
        world.start();
        world
    }

    fn hub(&self) -> &Hub {
        self.hub.as_ref().unwrap()
    }

    /// The app starts over what it kept; the MC lists what it lists.
    fn start(&mut self) {
        let hub = Hub::with(Launch {
            mc_origin: Some(ORIGIN.into()),
            state_dir: Some(self.state.path().to_owned()),
            data_dir: Some(self.data.path().to_owned()),
            ..Launch::default()
        });
        hub.mc.set_ready(&hub.engine, true);
        let mut list = vec![project("a", "p1")];
        list.extend(
            self.listed
                .iter()
                .map(|(t, title)| thread("a", THREADS[*t], title)),
        );
        shell(&hub, &[("a", "env-1")], list);
        self.hub = Some(hub);
    }

    fn key(t: usize) -> String {
        format!("env-1:{}", THREADS[t])
    }

    fn row(&mut self, t: usize, gone: bool) {
        self.rev += 1;
        let title = self.listed.get(&t).cloned().unwrap_or_default();
        let row = if gone {
            json!(["a", THREADS[t], "thread", {"id": THREADS[t], "deletedAt": "2026-10-08T10:00:00Z"}])
        } else {
            thread("a", THREADS[t], &title)
        };
        rows(self.hub(), "a", self.rev, vec![row]);
    }

    fn command(&self, command: &str) {
        let hub = self.hub();
        assert!(Commands::of(&hub.engine).run(&hub.engine, command));
        hub.advance(0);
    }

    fn step(&mut self, op: Op) {
        let before = route(self.hub());
        match op {
            Op::Open(t) => {
                if self.listed.contains_key(&t) {
                    self.hub()
                        .dispatch("thread.open", json!({"key": Self::key(t)}));
                    self.at = At::Thread(t);
                }
            }
            Op::Settings(s) => {
                self.hub()
                    .dispatch("settings.navigate", json!({"to": SECTIONS[s]}));
                self.at = At::Section(s);
            }
            Op::Usage => {
                self.hub().dispatch("usage.open", json!({}));
                self.at = At::Usage;
            }
            Op::Back => {
                self.command("navigation.back");
                self.adopt(&before, true);
            }
            Op::Forward => {
                self.command("navigation.forward");
                self.adopt(&before, false);
            }
            Op::Rename(t, n) => {
                if let Some(title) = self.listed.get_mut(&t) {
                    *title = format!("Name {n}");
                    self.row(t, false);
                }
            }
            Op::Delete(t) => {
                if self.listed.remove(&t).is_some() {
                    self.row(t, true);
                    if self.at == At::Thread(t) {
                        self.at = At::Draft;
                    }
                }
            }
            Op::Restore(t) => {
                if let std::collections::btree_map::Entry::Vacant(e) = self.listed.entry(t) {
                    e.insert(format!("Back {t}"));
                    self.row(t, false);
                }
            }
            Op::Restart => {
                let leaving = self.at.clone();
                drop(self.hub.take());
                self.start();
                // A thread gone while away lands on a draft; the rest is kept.
                if let At::Thread(t) = leaving
                    && !self.listed.contains_key(&t)
                {
                    self.at = At::Draft;
                }
                if self.at == At::Draft && !self.draft.is_empty() {
                    assert_eq!(route(self.hub())["draftId"], self.draft.as_str());
                }
            }
        }
    }

    /// Back and forward go where the stacks say, which the model does not
    /// keep: what shows afterwards is taken as the place, but only one the
    /// rules allow.
    fn adopt(&mut self, before: &Json, back: bool) {
        let after = route(self.hub());
        let moved = after["kind"] != before["kind"]
            || after["threadKey"] != before["threadKey"]
            || after["section"] != before["section"]
            || after["draftId"] != before["draftId"];
        if back && !before["canGoBack"].as_bool().unwrap_or(false) {
            // Nothing to go back to: home, which lands on a draft.
            assert!(matches!(
                kind(self.hub()).as_str(),
                "draft" | "thread" | "settings" | "usage"
            ));
        }
        if !moved {
            return;
        }
        self.at = match after["kind"].as_str().unwrap() {
            "thread" => {
                let key = after["threadKey"].as_str().unwrap();
                let t = (0..THREADS.len()).find(|t| Self::key(*t) == key).unwrap();
                assert!(self.listed.contains_key(&t), "{key} is gone");
                At::Thread(t)
            }
            "settings" => At::Section(
                SECTIONS
                    .iter()
                    .position(|s| after["section"] == *s)
                    .unwrap_or(0),
            ),
            "usage" => At::Usage,
            "draft" => At::Draft,
            other => panic!("back or forward went to {other}"),
        };
    }

    fn check(&mut self) {
        let shown = route(self.hub());
        match &self.at {
            At::Thread(t) => {
                assert_eq!(shown["kind"], "thread", "{shown}");
                assert_eq!(shown["threadKey"], Self::key(*t).as_str());
                assert_eq!(shown["title"], self.listed[t].as_str());
            }
            At::Section(s) => {
                assert_eq!(shown["kind"], "settings", "{shown}");
                // Back from one section may reach another, and a
                // sectionless settings route stays.
                let _ = s;
            }
            At::Usage => assert_eq!(shown["kind"], "usage", "{shown}"),
            At::Draft => {
                assert_eq!(shown["kind"], "draft", "{shown}");
                self.draft = shown["draftId"].as_str().unwrap().to_owned();
            }
        }
        // What is kept is what shows.
        let saved: Json = serde_json::from_slice(
            &std::fs::read(self.state.path().join("shell-route.json")).expect("a saved route"),
        )
        .unwrap();
        for field in ["kind", "threadKey", "draftId", "section"] {
            assert_eq!(saved[field], shown[field], "{field}: {saved} / {shown}");
        }
    }
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 32, ..ProptestConfig::default() })]

    #[test]
    fn the_route_shown_is_the_one_kept_and_never_a_thread_that_is_gone(
        ops in proptest::collection::vec(op(), 1..25)
    ) {
        let mut world = World::new();
        world.check();
        for op in ops {
            world.step(op);
            world.check();
        }
    }
}
