//! `pullRequestThread`, desktop-qt's PullRequestThreadController: starting a
//! thread on a pull request. The user names one (a URL, 42 or #42), sees
//! what it is, and chooses where it is checked out.
//!
//! Publishes `pullRequestThread`: null while closed, else {step ("ask",
//! "resolving", "choose" or "starting"), reference, error, pullRequest:
//! {number, title, branches ("feature/tax → main"), state} | null}.
//!
//! Actions: `pullRequestThread.open` (also the palette's "Start a thread on
//! a pull request…"; with {reference, environmentId, projectId}, as the
//! pull requests page sends for one no thread works on, it resolves that one
//! in that project at once), `pullRequestThread.resolve {reference}`
//! (`git.resolvePullRequest` in the project; nothing is checked out),
//! `pullRequestThread.start {mode: "local" | "worktree"}`
//! (`git.preparePullRequestThread`, then a thread on what it prepared, which
//! the window moves to) and `pullRequestThread.cancel`.

use std::rc::Rc;

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::commands::Commands;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::navigation::{Navigation, Route};
use crate::controllers::toasts::{DEFAULT_TIMEOUT_MS, Toasts};
use crate::controllers::workspace;
use crate::json::Json;
use crate::mc::Mc;
use crate::store;

const KEY: &str = "pullRequestThread";
const OPEN: &str = "pullRequestThread.open";

fn text<'a>(object: &'a Json, key: &str) -> &'a str {
    object.get(key).and_then(Json::as_str).unwrap_or("")
}

fn toast(engine: &Engine, kind: &'static str, title: &str, description: &str) {
    let (title, description) = (title.to_owned(), description.to_owned());
    Bridge::of(engine).defer(engine, move |engine| {
        controller::with::<Toasts, _>(engine, |t, e| {
            t.show(e, kind, &title, &description, None, DEFAULT_TIMEOUT_MS);
        });
    });
}

pub struct PullRequestThread {
    bridge: Bridge,
    mc: Rc<dyn Mc>,
    me: Me<PullRequestThread>,
    active: bool,
    /// Empty while closed.
    step: &'static str,
    environment: String,
    project: String,
    cwd: String,
    reference: String,
    error: String,
    /// `git.resolvePullRequest`'s pullRequest; null before.
    pull_request: Json,
    /// What is being asked: a reply for an older ask is dropped.
    generation: u64,
}

impl Controller for PullRequestThread {
    fn new(init: Init<'_, Self>) -> Self {
        PullRequestThread {
            bridge: init.bridge,
            mc: init.mc,
            me: init.me,
            active: false,
            step: "",
            environment: String::new(),
            project: String::new(),
            cwd: String::new(),
            reference: String::new(),
            error: String::new(),
            pull_request: Json::Null,
            generation: 0,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let me = self.me.clone();
        Commands::of(engine).add(
            engine,
            OPEN,
            "Start a thread on a pull request…",
            move |engine| me.run(engine, |c, engine| c.open(engine, &Json::Null)),
        );
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !self.active || !action.starts_with("pullRequestThread.") {
            return false;
        }
        match action {
            OPEN => self.open(engine, payload),
            "pullRequestThread.cancel" if self.step != "starting" => self.close(engine),
            "pullRequestThread.resolve" => self.resolve(engine, text(payload, "reference")),
            "pullRequestThread.start" => self.start(engine, text(payload, "mode")),
            _ => {}
        }
        true
    }
}

impl PullRequestThread {
    /// Opens the dialog on the route's project, or, `named` a `reference`
    /// with the `environmentId` and `projectId` it belongs to, resolves it
    /// there.
    fn open(&mut self, engine: &Engine, named: &Json) {
        let reference = text(named, "reference");
        if !reference.is_empty() {
            let environment = text(named, "environmentId");
            let project = text(named, "projectId");
            let root = store::with(engine, |s| {
                s.project_row(environment, project)
                    .and_then(|row| row.get("workspaceRoot"))
                    .and_then(Json::as_str)
                    .unwrap_or("")
                    .to_owned()
            });
            if root.is_empty() {
                toast(
                    engine,
                    "error",
                    "That pull request's project is not open on this device.",
                    "",
                );
                return;
            }
            self.environment = environment.to_owned();
            self.project = project.to_owned();
            self.cwd = root;
            self.step = "ask";
            self.error.clear();
            self.pull_request = Json::Null;
            let reference = reference.to_owned();
            self.resolve(engine, &reference);
            return;
        }
        let Some(place) = workspace::place(engine).filter(|p| !p.root.is_empty()) else {
            toast(
                engine,
                "error",
                "Open a project to start a thread on one of its pull requests.",
                "",
            );
            return;
        };
        self.environment = place.environment_id;
        self.project = place.project_id;
        self.cwd = place.root;
        self.step = "ask";
        self.reference.clear();
        self.error.clear();
        self.pull_request = Json::Null;
        self.generation += 1;
        self.publish(engine);
    }

    fn close(&mut self, engine: &Engine) {
        self.step = "";
        self.generation += 1;
        self.publish(engine);
    }

    fn resolve(&mut self, engine: &Engine, reference: &str) {
        let named = reference.trim();
        if self.step.is_empty() || self.step == "starting" || named.is_empty() {
            return;
        }
        self.reference = named.to_owned();
        self.error.clear();
        self.pull_request = Json::Null;
        self.step = "resolving";
        self.publish(engine);
        self.generation += 1;
        let generation = self.generation;
        let me = self.me.clone();
        self.mc.call(
            &self.environment,
            "git.resolvePullRequest",
            json!({"cwd": self.cwd, "reference": named}),
            Box::new(move |engine, result| {
                me.run(engine, |c, engine| {
                    if generation != c.generation {
                        return;
                    }
                    match result {
                        Err(e) => {
                            c.step = "ask";
                            c.error = if e.message.is_empty() {
                                "The pull request was not found.".into()
                            } else {
                                e.message
                            };
                        }
                        Ok(result) => {
                            c.pull_request = result
                                .get("pullRequest")
                                .filter(|p| p.is_object())
                                .cloned()
                                .unwrap_or(json!({}));
                            c.step = "choose";
                        }
                    }
                    c.publish(engine);
                });
            }),
        );
    }

    /// The checkout failed, or the thread could not be launched: back to
    /// choosing, saying why.
    fn failed(&mut self, engine: &Engine, generation: u64, reason: String) {
        if generation != self.generation {
            return;
        }
        self.step = "choose";
        self.error = if reason.is_empty() {
            "The pull request could not be checked out.".into()
        } else {
            reason
        };
        self.publish(engine);
    }

    fn start(&mut self, engine: &Engine, mode: &str) {
        if self.step != "choose" || !matches!(mode, "local" | "worktree") {
            return;
        }
        self.step = "starting";
        self.error.clear();
        self.publish(engine);
        self.generation += 1;
        let generation = self.generation;
        let thread_id = hal_c2_mc::new_uuid();
        let me = self.me.clone();
        let mc = self.mc.clone();
        self.mc.call(
            &self.environment,
            "git.preparePullRequestThread",
            json!({"cwd": self.cwd, "reference": self.reference, "mode": mode, "threadId": thread_id}),
            Box::new(move |engine, result| {
                let prepared = match result {
                    Ok(prepared) => prepared,
                    Err(e) => {
                        return me.run(engine, |c, engine| c.failed(engine, generation, e.message));
                    }
                };
                let mut launch = None;
                me.run(engine, |c, engine| {
                    if generation == c.generation {
                        launch = Some((c.environment.clone(), c.launch(engine, &thread_id, &prepared)));
                    }
                });
                let Some((environment, launch)) = launch else {
                    return;
                };
                // A checkout kept off the pull request's head, for the
                // local changes in it.
                let behind = !prepared
                    .get("isOnPullRequestHead")
                    .and_then(Json::as_bool)
                    .unwrap_or(true);
                let key = format!("{environment}:{thread_id}");
                mc.call(
                    &environment,
                    "orchestration.launchThread",
                    launch,
                    Box::new(move |engine, result| {
                        let mut launched = false;
                        me.run(engine, |c, engine| {
                            if generation != c.generation {
                                return;
                            }
                            match result {
                                Err(e) => c.failed(engine, generation, e.message),
                                Ok(_) => {
                                    c.close(engine);
                                    launched = true;
                                }
                            }
                        });
                        if !launched {
                            return;
                        }
                        if behind {
                            toast(
                                engine,
                                "warning",
                                "The checkout is not on the pull request's head",
                                "Its local changes were kept.",
                            );
                        }
                        Bridge::of(engine).defer(engine, move |engine| {
                            controller::with::<Navigation, _>(engine, |n, e| {
                                n.open(e, Route::Thread(key));
                            });
                        });
                    }),
                );
            }),
        );
    }

    /// `orchestration.launchThread`'s input for a thread on what was
    /// prepared.
    fn launch(&self, engine: &Engine, thread_id: &str, prepared: &Json) -> Json {
        let worktree = text(prepared, "worktreePath");
        let mut strategy = json!({
            "type": if worktree.is_empty() { "root" } else { "existing_worktree" },
            "branch": prepared.get("branch").cloned().unwrap_or(Json::Null),
        });
        if !worktree.is_empty() {
            strategy["worktreePath"] = json!(worktree);
        }
        let number = self
            .pull_request
            .get("number")
            .and_then(Json::as_i64)
            .unwrap_or(0);
        let mut launch = json!({
            "commandId": hal_c2_mc::new_uuid(),
            "creationSource": "web",
            "threadId": thread_id,
            "projectId": self.project,
            "title": format!("#{number} {}", text(&self.pull_request, "title")),
            "runtimeMode": "full-access",
            "interactionMode": "default",
            "workspaceStrategy": strategy,
        });
        // The project's default model, when it has one; the MC's otherwise.
        let model = store::with(engine, |s| {
            s.project_row(&self.environment, &self.project)
                .and_then(|row| row.get("defaultModelSelection"))
                .filter(|m| m.is_object())
                .cloned()
        });
        if let Some(model) = model {
            launch["modelSelection"] = model;
        }
        launch
    }

    fn publish(&self, engine: &Engine) {
        if self.step.is_empty() {
            self.bridge.publish(engine, KEY, Json::Null);
            return;
        }
        let pull_request = match self.pull_request.as_object() {
            Some(p) if !p.is_empty() => json!({
                "number": self.pull_request.get("number").and_then(Json::as_i64).unwrap_or(0),
                "title": text(&self.pull_request, "title"),
                "branches": format!(
                    "{} → {}",
                    text(&self.pull_request, "headBranch"),
                    text(&self.pull_request, "baseBranch")
                ),
                "state": text(&self.pull_request, "state"),
            }),
            _ => Json::Null,
        };
        self.bridge.publish(
            engine,
            KEY,
            json!({
                "step": self.step,
                "reference": self.reference,
                "error": self.error,
                "pullRequest": pull_request,
            }),
        );
    }
}
