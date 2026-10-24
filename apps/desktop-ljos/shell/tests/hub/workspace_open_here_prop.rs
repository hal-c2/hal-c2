//! `workspace::open_here`: an editor or the file manager starts only on the
//! machine the user sits at. The MC and a cluster member each say which
//! machine they run on (`platform.machineId`: this one, another, or none) and
//! change their minds; the member joins late; the MC drops and comes back,
//! announcing what changed meanwhile in its snapshot; the user goes between a
//! thread of each and opens files, the file manager and the workspace. The
//! port of desktop-qt's tests/prop/tst_WorkspaceOpenHereProp.cpp.
//!
//! The model is where the shell may start one: the environment says it is
//! on this machine, or, saying nothing, it is the shell's own MC on a
//! loopback address (the fake MC's). Every open there asks that
//! environment's MC to start it on the path. A member's file elsewhere opens
//! from the folder the shell's MC keeps for it, when that MC runs here and
//! answers files.localPath with one (an older MC answers null, one without
//! FUSE says why); the shell's MC starts it there. Every other open asks no
//! MC to start anything and tells the user why. Whichever thread is open,
//! the editors offered are this machine's: the thread's environment's when
//! it runs here, else the shell's own.

use hal_c2_shell::Launch;
use hal_c2_shell::controllers::workspace::{self, FILES_ELSEWHERE};
use hal_c2_shell::json::Json;
use hal_c2_shell::this_machine;
use proptest::prelude::*;
use serde_json::json;

use crate::Hub;

const HERE: &str = "5e1f00000000000000000000000000000000000000000000000000000000c0de";
const ELSEWHERE: &str = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
const OWN: &str = "env-1";
const MEMBER: &str = "env-c";
const FOLDERS: &str = "/home/user/.local/state/hal-c2/elixir/machines";
const NO_FUSE: &str = "The file is on \"env-c\". To open it here, install FUSE 3 (fuse3).";
const AT: &str = "2026-10-16T08:00:00Z";

#[derive(Clone, Copy, Debug, PartialEq)]
enum Machine {
    Here,
    Elsewhere,
    Unsaid,
}

#[derive(Clone, Copy, Debug)]
enum Open {
    File,
    Reveal,
    Workspace,
}

/// How the shell's MC answers files.localPath for the member.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Folder {
    Older,
    Mounted,
    NoFuse,
}

#[derive(Clone, Debug)]
enum Op {
    /// The MC (0) or the member (1) says which machine it runs on.
    Announce(usize, Machine),
    Join,
    Go(usize),
    Answer(Folder),
    Drop,
    Reconnect,
    OpenIt(Open),
}

fn machine() -> impl Strategy<Value = Machine> {
    prop_oneof![
        Just(Machine::Here),
        Just(Machine::Elsewhere),
        Just(Machine::Unsaid)
    ]
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        3 => (0..2_usize, machine()).prop_map(|(w, m)| Op::Announce(w, m)),
        1 => Just(Op::Join),
        2 => (0..2_usize).prop_map(Op::Go),
        1 => prop_oneof![
            Just(Folder::Older),
            Just(Folder::Mounted),
            Just(Folder::NoFuse)
        ]
        .prop_map(Op::Answer),
        1 => Just(Op::Drop),
        1 => Just(Op::Reconnect),
        3 => prop_oneof![Just(Open::File), Just(Open::Reveal), Just(Open::Workspace)]
            .prop_map(Op::OpenIt),
    ]
}

fn platform_of(machine: Machine) -> Option<Json> {
    match machine {
        Machine::Here => Some(json!({"machineId": HERE})),
        Machine::Elsewhere => Some(json!({"machineId": ELSEWHERE})),
        Machine::Unsaid => None,
    }
}

/// Each MC's editors, told apart so the list offered says whose it is.
fn editors_of(member: bool) -> [&'static str; 2] {
    if member {
        ["zed", "file-manager"]
    } else {
        ["vscode", "file-manager"]
    }
}

fn environment_of(which: usize) -> &'static str {
    if which == 0 { OWN } else { MEMBER }
}

fn key_of(which: usize) -> &'static str {
    if which == 0 { "env-1:t1" } else { "env-c:t7" }
}

fn root_of(which: usize) -> &'static str {
    if which == 0 { "/work/p1" } else { "/work/ops" }
}

#[derive(Clone, Debug)]
struct Model {
    own: Machine,
    member: Machine,
    joined: bool,
    connected: bool,
    folder: Folder,
    /// The thread open: the MC's own (0) or the member's (1).
    route: Option<usize>,
}

impl Model {
    fn here(&self, which: usize) -> bool {
        // Unsaid, the shell's own MC is here by its loopback address; a
        // member never is.
        if which == 0 {
            self.own != Machine::Elsewhere
        } else {
            self.member == Machine::Here
        }
    }
}

/// Unpins this machine's id when the case ends, also on a failure.
struct Pinned;

impl Drop for Pinned {
    fn drop(&mut self) {
        this_machine::set_id_for_testing(None);
    }
}

struct World {
    hub: Hub,
    model: Model,
    /// Every `shell.openInEditor`: the environment it was for and its
    /// payload.
    opened: Vec<(String, Json)>,
    /// files.localPath asked of anything but the shell's MC for the member.
    misasked: Vec<String>,
    _pinned: Pinned,
}

impl World {
    fn new() -> World {
        this_machine::set_id_for_testing(Some(HERE.into()));
        // This device keeps the editor last used.
        let dir = std::path::PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("hub-open-here");
        let _ = std::fs::remove_dir_all(&dir);
        let hub = Hub::with(Launch {
            mc_origin: Some("http://127.0.0.1:1".into()),
            config_dir: Some(dir),
            ..Launch::default()
        });
        hub.mc.set_ready(&hub.engine, true);
        let world = World {
            hub,
            model: Model {
                own: Machine::Unsaid,
                member: Machine::Unsaid,
                joined: false,
                connected: true,
                folder: Folder::Older,
                route: None,
            },
            opened: Vec::new(),
            misasked: Vec::new(),
            _pinned: Pinned,
        };
        world.snapshot();
        world.configs();
        world
    }

    fn descriptor(environment: &str, machine: Machine) -> Json {
        let mut descriptor = json!({"environmentId": environment});
        if let Some(platform) = platform_of(machine) {
            descriptor["platform"] = platform;
        }
        descriptor
    }

    /// The MC's snapshot as the model has it.
    fn snapshot(&self) {
        let m = &self.model;
        let mut mcs = vec![json!({"mc": "a", "online": true, "epoch": "e", "rev": 1,
            "environment": World::descriptor(OWN, m.own)})];
        let mut rows = vec![
            json!(["a", "p1", "project", {"id": "p1", "title": "p1", "workspaceRoot": root_of(0),
                "createdAt": AT, "updatedAt": AT}]),
            json!(["a", "t1", "thread", {"id": "t1", "title": "t1", "projectId": "p1",
                "createdAt": AT, "updatedAt": AT}]),
        ];
        if m.joined {
            mcs.push(json!({"mc": "mc-c", "online": true, "epoch": "e", "rev": 1,
                "environment": World::descriptor(MEMBER, m.member)}));
            rows.push(
                json!(["mc-c", "ops", "project", {"id": "ops", "title": "ops",
                "workspaceRoot": root_of(1), "createdAt": AT, "updatedAt": AT}]),
            );
            rows.push(json!(["mc-c", "t7", "thread", {"id": "t7", "title": "t7",
                "projectId": "ops", "createdAt": AT, "updatedAt": AT}]));
        }
        self.hub.mc.frame(
            &self.hub.engine,
            "shell",
            "",
            json!({"t": "shell", "mcs": mcs, "rows": rows}),
        );
    }

    /// Each environment's config to whoever follows it: the shell's to
    /// every follower first (its own may name no environment), then the
    /// member's to the member's followers.
    fn configs(&self) {
        for (which, environment) in [(0, ""), (1, MEMBER)] {
            let config = json!({"settings": {}, "availableEditors": editors_of(which == 1),
                "shellRevealInFileManager": true});
            self.hub.mc.frame(
                &self.hub.engine,
                "config",
                environment,
                json!({"t": "config", "config": config}),
            );
        }
    }

    /// Answers what the shell asked: where the member's file is here, then
    /// the apps it starts; until nothing is left.
    fn answer(&mut self) {
        loop {
            let mc = &self.hub.mc;
            if let Some(index) = mc.pending("files.localPath") {
                let (environment, payload) = {
                    let calls = mc.calls.borrow();
                    (calls[index].0.clone(), calls[index].2.clone())
                };
                let path = payload["path"].as_str().unwrap_or_default();
                let answer = if environment != OWN || payload["environmentId"] != MEMBER {
                    self.misasked.push(format!("{environment} {payload}"));
                    Json::Null
                } else {
                    match self.model.folder {
                        Folder::Older => Json::Null,
                        Folder::Mounted => json!({"path": format!("{FOLDERS}/{MEMBER}{path}")}),
                        Folder::NoFuse => {
                            json!({"reason": "no_fuse", "machine": MEMBER, "message": NO_FUSE})
                        }
                    }
                };
                mc.reply(&self.hub.engine, index, Ok(answer));
                continue;
            }
            if let Some(index) = mc.pending("shell.openInEditor") {
                let call = mc.calls.borrow()[index].clone();
                self.opened.push((call.0, call.2));
                mc.reply(&self.hub.engine, index, Ok(Json::Null));
                continue;
            }
            return;
        }
    }

    fn offered(&self) -> Vec<String> {
        self.hub.published("workspace")["editors"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|e| e["id"].as_str().map(str::to_owned))
            .collect()
    }

    /// The newest toast's id and title.
    fn newest_toast(&self) -> (String, String) {
        let toasts = self.hub.published("toasts");
        let first = &toasts["items"][0];
        (
            first["id"].as_str().unwrap_or_default().to_owned(),
            first["title"].as_str().unwrap_or_default().to_owned(),
        )
    }

    fn step(&mut self, op: &Op) -> Result<(), TestCaseError> {
        match *op {
            Op::Announce(which, machine) => {
                if which == 1 && !self.model.joined {
                    return Ok(());
                }
                if which == 0 {
                    self.model.own = machine;
                } else {
                    self.model.member = machine;
                }
                // Unheard while the MC is down; its snapshot says so on the
                // way back.
                if self.model.connected {
                    let (mc, environment) = if which == 0 {
                        ("a", OWN)
                    } else {
                        ("mc-c", MEMBER)
                    };
                    self.hub.mc.frame(
                        &self.hub.engine,
                        "shell",
                        "",
                        json!({"t": "shell.environment", "mc": mc,
                            "environment": World::descriptor(environment, machine)}),
                    );
                }
            }
            Op::Join => {
                if self.model.joined || !self.model.connected {
                    return Ok(());
                }
                self.model.joined = true;
                self.snapshot();
                self.configs();
            }
            Op::Go(which) => {
                if !self.model.connected || (which == 1 && !self.model.joined) {
                    return Ok(());
                }
                self.model.route = Some(which);
                self.hub
                    .dispatch("thread.open", json!({"key": key_of(which)}));
                self.configs();
                prop_assert_eq!(
                    &self.hub.published("workspace")["threadKey"],
                    &json!(key_of(which))
                );
            }
            Op::Answer(folder) => self.model.folder = folder,
            Op::Drop => {
                if !self.model.connected {
                    return Ok(());
                }
                self.model.connected = false;
                self.hub.mc.set_ready(&self.hub.engine, false);
            }
            Op::Reconnect => {
                if self.model.connected {
                    return Ok(());
                }
                self.model.connected = true;
                self.hub.mc.set_ready(&self.hub.engine, true);
                self.snapshot();
                self.configs();
            }
            Op::OpenIt(open) => {
                let Some(which) = self.model.route.filter(|_| self.model.connected) else {
                    return Ok(());
                };
                self.open_it(which, open)?;
            }
        }
        self.answer();
        prop_assert!(self.misasked.is_empty(), "{:?}", self.misasked);
        Ok(())
    }

    fn open_it(&mut self, which: usize, open: Open) -> Result<(), TestCaseError> {
        let model = self.model.clone();
        // This machine's editors: the thread's MC's when it runs here, else
        // the shell's.
        let expected = editors_of(which == 1 && model.here(1));
        prop_assert_eq!(self.offered(), expected.to_vec());

        let editor = match open {
            Open::Reveal => "file-manager",
            _ => expected[0],
        };
        let path = match open {
            Open::Workspace => root_of(which).to_owned(),
            _ => format!("{}/src/app.ts", root_of(which)),
        };
        let before = self.opened.len();
        let toast_before = self.newest_toast().0;
        match open {
            Open::Workspace => {
                self.hub
                    .dispatch("workspace.openInEditor", json!({"editorId": editor}));
            }
            Open::File => {
                prop_assert!(workspace::open_in_editor(
                    &self.hub.engine,
                    editor,
                    &path,
                    false
                ));
            }
            Open::Reveal => {
                prop_assert!(workspace::open_in_editor(&self.hub.engine, "", &path, true));
            }
        }
        self.answer();
        let (toast, title) = self.newest_toast();
        // A member's file elsewhere is in the shell's MC's folder for it,
        // when that MC runs here.
        let asked = !model.here(which) && which == 1 && model.here(0);
        let mounted = asked && model.folder == Folder::Mounted;
        if model.here(which) || mounted {
            let cwd = if mounted {
                format!("{FOLDERS}/{MEMBER}{path}")
            } else {
                path.clone()
            };
            let mut payload = json!({"cwd": cwd, "editor": editor});
            if matches!(open, Open::Reveal) {
                payload["reveal"] = true.into();
            }
            prop_assert_eq!(self.opened.len(), before + 1);
            let launcher = if mounted { OWN } else { environment_of(which) };
            prop_assert_eq!(&self.opened[before], &(launcher.to_owned(), payload));
            prop_assert_eq!(toast, toast_before, "told {}", title);
        } else {
            prop_assert_eq!(self.opened.len(), before);
            prop_assert_ne!(toast, toast_before);
            let told = if asked && model.folder == Folder::NoFuse {
                NO_FUSE
            } else {
                FILES_ELSEWHERE
            };
            prop_assert_eq!(title, told);
        }
        Ok(())
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(64))]

    #[test]
    fn an_editor_or_the_file_manager_starts_only_on_this_machine(
        ops in proptest::collection::vec(op(), 1..30),
    ) {
        let mut world = World::new();
        for op in &ops {
            world.step(op)?;
        }
    }
}
