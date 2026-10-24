//! The Files tab's core saving edits against an MC that holds every write
//! and answers them in any order. Two environments: env-a's session has
//! terminal access, env-b's does not, so env-b refuses a write by full path
//! (a file outside the workspace) for want of terminal:operate, as the MC's
//! socket does (apps/server-ex lib/hal_c2/rpc.ex required_scope/2).
//! Meanwhile the user moves between the environments and between a project
//! file and two files outside it, edits, and closes. The port of
//! desktop-qt's tests/prop/tst_WorkspaceFilesSaveProp.cpp.
//!
//! What the user is promised: a write only ever carries the text of the file
//! it writes; once an environment refused a write by full path, its files
//! outside the workspace open read-only and nothing more is sent to it by
//! full path; every other edit is still written once its writes are
//! answered.

use std::collections::{HashMap, HashSet};

use hal_c2_shell::json::Json;
use hal_c2_shell::mc::McError;
use hal_c2_shell::thread_view::workspace_files::{Effect, Files, Then};
use proptest::prelude::*;
use serde_json::json;

const ENVIRONMENTS: [&str; 2] = ["env-a", "env-b"];
const PATHS: [&str; 3] = ["a.txt", "/tmp/x.txt", "/tmp/y.txt"];
const ROOT: &str = "/w";

fn outside(path: &str) -> bool {
    path.starts_with('/')
}

fn key(environment: &str, path: &str) -> (String, String) {
    (environment.to_owned(), path.to_owned())
}

/// What the user sees and does; the rest is read off the MC.
#[derive(Clone, Debug, Default)]
struct Model {
    environment: String,
    open_path: String,
    /// Edits so far, so each is new text.
    edits: u32,
}

struct Write {
    environment: String,
    path: String,
    contents: String,
    then: Then,
}

struct Sut {
    files: Files,
    /// Each environment's disk, by path: every file starts as
    /// "<environment>:<path>".
    disk: HashMap<(String, String), String>,
    held: Vec<Write>,
    /// The environments that refused a write by full path.
    refused: HashSet<String>,
    /// Writes by full path sent after their environment refused one.
    resent: Vec<String>,
    /// The user edited the file since opening it. (Read again, it may show
    /// the text from before a write still under way: the MC answers each
    /// call on its own.)
    edited: bool,
    /// The wait before an edit is written runs (it is 0 here, so it ends
    /// once nothing else is to be done).
    save_due: bool,
}

impl Sut {
    fn new() -> Sut {
        let mut disk = HashMap::new();
        for environment in ENVIRONMENTS {
            for path in PATHS {
                disk.insert(key(environment, path), format!("{environment}:{path}"));
            }
        }
        Sut {
            files: Files::new(),
            disk,
            held: Vec::new(),
            refused: HashSet::new(),
            resent: Vec::new(),
            edited: false,
            save_due: false,
        }
    }

    /// Runs what the core asked for until it asks for nothing more: reads are
    /// answered from the disk as it is, writes are held.
    fn pump(&mut self) {
        for _ in 0..100 {
            let effects = self.files.take_effects();
            self.files.take_signals();
            if effects.is_empty() {
                if !std::mem::take(&mut self.save_due) {
                    return;
                }
                self.files.save_due();
                continue;
            }
            let mut reads = Vec::new();
            for effect in effects {
                match effect {
                    Effect::Call {
                        environment,
                        method,
                        payload,
                        then,
                    } => {
                        let path = payload["relativePath"].as_str().unwrap_or("").to_owned();
                        match method {
                            "projects.readFile" => reads.push((environment, path, then)),
                            "projects.writeFile" => {
                                if outside(&path) && self.refused.contains(&environment) {
                                    self.resent.push(format!("{environment} {path}"));
                                }
                                let contents =
                                    payload["contents"].as_str().unwrap_or("").to_owned();
                                self.held.push(Write {
                                    environment,
                                    path,
                                    contents,
                                    then,
                                });
                            }
                            _ => {}
                        }
                    }
                    Effect::SaveTimer(start) => self.save_due = start,
                    _ => {}
                }
            }
            for (environment, path, then) in reads {
                let contents = self
                    .disk
                    .get(&key(&environment, &path))
                    .cloned()
                    .unwrap_or_default();
                self.files.answer(
                    then,
                    Ok::<_, McError>(json!({"relativePath": path, "contents": contents})),
                );
            }
        }
        panic!("the core kept asking");
    }

    /// The MC answers the `index`th write it holds: env-b refuses one by
    /// full path.
    fn answer(&mut self, index: usize) {
        let write = self.held.remove(index);
        let result: Result<Json, McError> = if outside(&write.path) && write.environment == "env-b"
        {
            self.refused.insert(write.environment.clone());
            Err(McError {
                message: "terminal:operate is required".into(),
                detail: json!({
                    "_tag": "EnvironmentScopeRequiredError",
                    "requiredScope": "terminal:operate",
                }),
            })
        } else {
            self.disk
                .insert(key(&write.environment, &write.path), write.contents);
            Ok(json!({"relativePath": write.path}))
        };
        self.files.answer(write.then, result);
        self.pump();
    }
}

#[derive(Clone, Debug)]
enum Op {
    Target(usize),
    Open(usize),
    /// The user types at the end of the open file, if they can.
    Edit,
    /// The MC answers one write it holds, if any.
    Answer(usize),
    /// Every write is answered, the next ones too.
    Settle,
    Close,
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        1 => (0..ENVIRONMENTS.len()).prop_map(Op::Target),
        2 => (0..PATHS.len()).prop_map(Op::Open),
        2 => Just(Op::Edit),
        2 => (0..4_usize).prop_map(Op::Answer),
        1 => Just(Op::Settle),
        1 => Just(Op::Close),
    ]
}

fn check(model: &Model, sut: &Sut) -> Result<(), TestCaseError> {
    let files = &sut.files;
    prop_assert_eq!(files.environment(), model.environment.as_str());
    prop_assert_eq!(files.open_path(), model.open_path.as_str());
    prop_assert!(sut.resent.is_empty(), "resent {:?}", sut.resent);
    // A write carries only its own file's text: what it held, edited.
    for write in &sut.held {
        let own = format!("{}:{}", write.environment, write.path);
        prop_assert!(write.contents.starts_with(&own), "{}", write.contents);
    }
    for ((environment, path), text) in &sut.disk {
        prop_assert!(text.starts_with(&format!("{environment}:{path}")), "{text}");
    }
    // env-b's files outside the workspace are never written.
    for path in PATHS.into_iter().filter(|p| outside(p)) {
        prop_assert_eq!(&sut.disk[&key("env-b", path)], &format!("env-b:{path}"));
    }
    if model.open_path.is_empty() {
        return Ok(());
    }
    prop_assert_eq!(files.file_status(), "ready");
    let read_only = outside(&model.open_path) && sut.refused.contains(&model.environment);
    prop_assert_eq!(files.editable(), !read_only);
    prop_assert_eq!(files.read_only_reason().is_empty(), !read_only);
    Ok(())
}

fn run(ops: Vec<Op>) -> Result<(), TestCaseError> {
    let mut model = Model::default();
    let mut sut = Sut::new();
    for op in ops {
        let before = model.clone();
        match op {
            Op::Target(i) => {
                let environment = ENVIRONMENTS[i];
                if environment != model.environment {
                    model.environment = environment.to_owned();
                    model.open_path.clear();
                    sut.edited = false;
                }
                sut.files.set_target(environment, ROOT, "");
            }
            Op::Open(i) => {
                if model.environment.is_empty() {
                    continue;
                }
                let path = PATHS[i];
                if path != model.open_path {
                    sut.edited = false;
                }
                model.open_path = path.to_owned();
                prop_assert!(sut.files.open_file(path, 0));
            }
            Op::Edit => {
                if model.open_path.is_empty() {
                    continue;
                }
                let editable = sut.files.editable();
                let text = sut.files.text().to_owned();
                sut.files.set_editing(true);
                sut.files.edit(&format!("{text} +{}", model.edits));
                model.edits += 1;
                // Read-only takes no edit.
                if !editable {
                    prop_assert_eq!(sut.files.text(), text.as_str());
                    prop_assert!(!sut.files.facts().editing);
                }
                sut.edited = sut.edited || editable;
            }
            Op::Answer(pick) => {
                sut.pump();
                if !sut.held.is_empty() {
                    let index = pick % sut.held.len();
                    sut.answer(index);
                }
            }
            Op::Settle => {
                sut.pump();
                for _ in 0..10 {
                    if sut.held.is_empty() {
                        break;
                    }
                    while !sut.held.is_empty() {
                        sut.answer(0);
                    }
                }
                prop_assert!(sut.held.is_empty());
                if !before.open_path.is_empty() && sut.files.file_status() == "ready" {
                    let on_disk = &sut.disk[&key(&before.environment, &before.open_path)];
                    let refused =
                        outside(&before.open_path) && sut.refused.contains(&before.environment);
                    if refused {
                        prop_assert_eq!(
                            on_disk,
                            &format!("{}:{}", before.environment, before.open_path)
                        );
                    } else {
                        prop_assert!(!sut.files.facts().unsaved);
                        if sut.edited {
                            prop_assert_eq!(on_disk.as_str(), sut.files.text());
                        }
                    }
                }
            }
            Op::Close => {
                model.open_path.clear();
                sut.edited = false;
                sut.files.close_file();
            }
        }
        sut.pump();
        check(&model, &sut)?;
    }
    Ok(())
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(128))]

    #[test]
    fn edits_are_written_to_their_own_file_never_by_full_path_where_that_was_refused(
        ops in proptest::collection::vec(op(), 1..40),
    ) {
        run(ops)?;
    }
}
