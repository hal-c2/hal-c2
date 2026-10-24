//! The header's git actions (GitController) against the MC's source
//! control (desktop-qt's GitSteps.cpp): source-control/git-actions.feature,
//! push-pull-and-default-branch.feature, and
//! commit-and-generated-messages.feature.
//!
//! [`FakeCheckout`] is one checkout at /work/<project> as the MC reports it
//! (`vcs` status) and changes it: `gitAction` runs commit, push and pull
//! request the way git_actions.ex does, with its stages, hook lines and
//! result toast; `vcs.pull`, `vcs.init`, `vcs.refreshStatus` and
//! `sourceControl.publishRepository` answer as the MC does.

use std::collections::BTreeMap;
use std::rc::Rc;

use chrono::Duration;
use hal_c2_shell::controllers::navigation::{Navigation, Route};
use ljos::prelude::Value;
use serde_json::{Map, json};

type Json = serde_json::Value;

use crate::brick::{Brick, Shown, shown};
use crate::fake_mc::{FakeMc, Rpc};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

const THREAD: &str = "t1";
const PR_URL: &str = "https://github.com/acme/shop/pull/42";
const NOT_AUTHENTICATED: &str =
    "GitHub is not authenticated. Open Settings -> Source Control for setup guidance.";

pub struct Commit {
    pub subject: String,
    pub files: Vec<String>,
    pub branch: String,
    pub sha: String,
}

pub struct FakeCheckout {
    pub cwd: String,
    pub remote_name: String,
    /// The MC has sent its status.
    pub known: bool,
    pub is_repo: bool,
    /// None on a detached HEAD.
    pub branch: Option<String>,
    pub default_branch: String,
    pub provider: String,
    pub has_remote: bool,
    pub upstream: bool,
    /// Local commits the upstream lacks, by subject.
    pub ahead: Vec<String>,
    pub behind: i64,
    pub ahead_of_default: Option<i64>,
    pub changed: Vec<String>,
    /// An open pull request for the branch.
    pub pr: bool,
    /// Every `gitAction` input.
    pub inputs: Vec<Json>,
    pub commits: Vec<Commit>,
    /// What each remote branch holds, by "origin/<branch>".
    pub remote: BTreeMap<String, Vec<String>>,
    /// Commits a pull brought in.
    pub pulled: i64,
    pub publishes: Vec<Json>,
    pub initialized: bool,
    pub generated_message: String,

    // What the next action does instead of finishing at once.
    /// The pre-commit hook prints it.
    pub hook_line: String,
    /// The action waits there until released.
    pub wait_after_hook: bool,
    /// The action waits while its message is written.
    pub wait_while_writing: bool,
    /// The stage a failing action fails in.
    pub fail_phase: String,
    pub held: Option<i64>,
    pub fail_with: String,
    /// The failure's remedy (GitActionFailureCta), when it has one.
    pub fail_cta: Json,
    pub refuse_pull: String,
    pub refuse_init: String,
    pub refuse_publish: String,
    /// A change made outside HAL-C2, seen when the MC next looks.
    pub outside_change: bool,
}

impl Default for FakeCheckout {
    fn default() -> FakeCheckout {
        FakeCheckout {
            cwd: String::new(),
            remote_name: "origin".into(),
            known: true,
            is_repo: true,
            branch: Some("feature/tax".into()),
            default_branch: "main".into(),
            provider: "github".into(),
            has_remote: true,
            upstream: true,
            ahead: Vec::new(),
            behind: 0,
            ahead_of_default: None,
            changed: Vec::new(),
            pr: false,
            inputs: Vec::new(),
            commits: Vec::new(),
            remote: BTreeMap::new(),
            pulled: 0,
            publishes: Vec::new(),
            initialized: false,
            generated_message: "Add tax to the cart line".into(),
            hook_line: String::new(),
            wait_after_hook: false,
            wait_while_writing: false,
            fail_phase: "commit".into(),
            held: None,
            fail_with: String::new(),
            fail_cta: Json::Null,
            refuse_pull: String::new(),
            refuse_init: String::new(),
            refuse_publish: String::new(),
            outside_change: false,
        }
    }
}

impl FakeCheckout {
    fn branch_name(&self) -> String {
        self.branch.clone().unwrap_or_default()
    }

    fn local(&self) -> Json {
        if !self.known {
            return json!({});
        }
        if !self.is_repo {
            return json!({"isRepo": false});
        }
        let files: Vec<Json> = self
            .changed
            .iter()
            .map(|path| json!({"path": path, "insertions": 3, "deletions": 1}))
            .collect();
        json!({
            "isRepo": true,
            "isDefaultRef": self.branch.as_deref() == Some(self.default_branch.as_str()),
            "hasWorkingTreeChanges": !self.changed.is_empty(),
            "hasPrimaryRemote": self.has_remote,
            "sourceControlProvider": {"kind": self.provider},
            "workingTree": {"files": files},
            "refName": self.branch,
        })
    }

    fn remote_status(&self) -> Json {
        if !self.known || !self.is_repo {
            return json!({});
        }
        let mut status = json!({
            "hasUpstream": self.upstream,
            "aheadCount": self.ahead.len(),
            "behindCount": self.behind,
            "pr": if self.pr {
                json!({"number": 42, "title": "Tax line", "url": PR_URL, "state": "open"})
            } else {
                Json::Null
            },
        });
        if let Some(n) = self.ahead_of_default {
            status["aheadOfDefaultCount"] = json!(n);
        }
        status
    }
}

/// The checkout's status, to whoever follows it.
fn send_status(mc: &mut FakeMc) {
    let (cwd, local, remote) = {
        let git = mc.part::<FakeCheckout>();
        (git.cwd.clone(), git.local(), git.remote_status())
    };
    for id in mc.subscribers("vcs") {
        if text(&mc.shape_of(id)["cwd"]) != cwd {
            continue;
        }
        mc.send(&json!({"t": "vcs", "id": id, "event": {"_tag": "localUpdated", "local": local}}));
        mc.send(
            &json!({"t": "vcs", "id": id, "event": {"_tag": "remoteUpdated", "remote": remote}}),
        );
    }
}

fn send_event(mc: &FakeMc, id: i64, event: Json) {
    mc.send(&json!({"t": "gitAction", "id": id, "event": event}));
}

fn phase(mc: &FakeMc, id: i64, phase: &str, label: &str) {
    send_event(
        mc,
        id,
        json!({"kind": "phase_started", "phase": phase, "label": label}),
    );
}

fn slug(text: &str) -> String {
    let mut slug = String::new();
    for c in text.to_lowercase().chars() {
        if c.is_ascii_lowercase() || c.is_ascii_digit() {
            slug.push(c);
        } else if !slug.ends_with('-') {
            slug.push('-');
        }
    }
    slug.trim_matches('-').to_owned()
}

/// The rest of the action, after the pre-commit hook (git_actions.ex run/3
/// and toast/2).
fn finish(mc: &mut FakeMc, id: i64, input: &Json) {
    let action = text(&input["action"]);
    let commits = action.starts_with("commit");
    let pushes = action.contains("push");
    let opens_pr = action.ends_with("pr");
    let mut message = text(&input["commitMessage"]);
    if message.is_empty() {
        message = mc.part::<FakeCheckout>().generated_message.clone();
    }

    let mut branch = json!({"status": "skipped_not_requested"});
    if input["featureBranch"].as_bool() == Some(true) {
        let git = mc.part::<FakeCheckout>();
        let name = format!("feature/{}", slug(&message));
        git.branch = Some(name.clone());
        git.upstream = false;
        branch = json!({"status": "created", "name": name});
    }

    let mut commit = json!({"status": "skipped_not_requested"});
    {
        let git = mc.part::<FakeCheckout>();
        if commits && !git.changed.is_empty() {
            let mut files = git.changed.clone();
            if let Some(paths) = input["filePaths"].as_array() {
                files = paths.iter().map(text).collect();
            }
            let sha = format!("abc{:04}def0123456789", git.commits.len() + 1);
            git.changed.retain(|f| !files.contains(f));
            git.ahead.push(message.clone());
            git.commits.push(Commit {
                subject: message.clone(),
                files,
                branch: git.branch_name(),
                sha: sha.clone(),
            });
            commit = json!({"status": "created", "commitSha": sha, "subject": message});
        }
    }

    let mut push = json!({"status": "skipped_not_requested"});
    if pushes || opens_pr {
        phase(mc, id, "push", "Pushing...");
        let git = mc.part::<FakeCheckout>();
        let target = format!("{}/{}", git.remote_name, git.branch_name());
        let ahead = std::mem::take(&mut git.ahead);
        git.remote.entry(target.clone()).or_default().extend(ahead);
        git.upstream = true;
        push = json!({"status": "pushed", "branch": git.branch_name(), "upstreamBranch": target});
    }

    let mut pr = json!({"status": "skipped_not_requested"});
    if opens_pr {
        phase(mc, id, "pr", "Preparing PR...");
        mc.part::<FakeCheckout>().pr = true;
        pr = json!({"status": "created", "number": 42, "title": message, "url": PR_URL});
    }

    let sha: String = text(&commit["commitSha"]).chars().take(7).collect();
    let on_default = {
        let git = mc.part::<FakeCheckout>();
        git.branch.as_deref() != Some(git.default_branch.as_str())
    };
    let mut toast;
    if opens_pr {
        toast = json!({"title": "Created PR #42", "description": message});
    } else if push["status"] == "pushed" {
        let spacer = if sha.is_empty() {
            String::new()
        } else {
            format!(" {sha}")
        };
        toast = json!({"title": format!("Pushed{spacer} to {}", text(&push["upstreamBranch"]))});
        if !sha.is_empty() {
            toast["description"] = json!(message);
        }
    } else if !sha.is_empty() {
        toast = json!({"title": format!("Committed {sha}"), "description": message});
    } else {
        toast = json!({"title": "Done"});
    }
    let mut cta = json!({"kind": "none"});
    if action == "commit" && !sha.is_empty() {
        cta = json!({"kind": "run_action", "label": "Push", "action": {"kind": "push"}});
    } else if opens_pr {
        cta = json!({"kind": "open_pr", "label": "View PR", "url": PR_URL});
    } else if pushes && on_default {
        cta = json!({"kind": "run_action", "label": "Create PR", "action": {"kind": "create_pr"}});
    }
    toast["cta"] = cta;

    send_status(mc);
    send_event(
        mc,
        id,
        json!({"kind": "action_finished", "result": {
            "action": action, "branch": branch, "commit": commit,
            "push": push, "pr": pr, "toast": toast}}),
    );
}

fn run(mc: &mut FakeMc, id: i64, input: Json) {
    mc.part::<FakeCheckout>().inputs.push(input.clone());
    let action = text(&input["action"]);
    send_event(
        mc,
        id,
        json!({"kind": "action_started", "phases": [action]}),
    );
    if action.starts_with("commit") {
        if input.get("commitMessage").is_none() {
            phase(mc, id, "commit", "Generating commit message...");
        }
        if mc.part::<FakeCheckout>().wait_while_writing {
            mc.part::<FakeCheckout>().held = Some(id);
            return;
        }
        phase(mc, id, "commit", "Committing...");
        let hook = mc.part::<FakeCheckout>().hook_line.clone();
        if !hook.is_empty() {
            send_event(
                mc,
                id,
                json!({"kind": "hook_started", "hookName": "pre-commit"}),
            );
            send_event(
                mc,
                id,
                json!({"kind": "hook_output", "hookName": "pre-commit",
                       "stream": "stdout", "text": format!("{hook}\n")}),
            );
        }
    }
    let (fail_with, fail_phase, fail_cta, wait, hook) = {
        let git = mc.part::<FakeCheckout>();
        (
            git.fail_with.clone(),
            git.fail_phase.clone(),
            git.fail_cta.clone(),
            git.wait_after_hook,
            git.hook_line.clone(),
        )
    };
    if !fail_with.is_empty() {
        let mut failed =
            json!({"kind": "action_failed", "phase": fail_phase, "message": fail_with});
        if fail_cta.as_object().is_some_and(|o| !o.is_empty()) {
            failed["cta"] = fail_cta;
        }
        send_event(mc, id, failed);
        return;
    }
    if wait {
        mc.part::<FakeCheckout>().held = Some(id);
        return;
    }
    if !hook.is_empty() {
        send_event(
            mc,
            id,
            json!({"kind": "hook_finished", "hookName": "pre-commit", "exitCode": 0}),
        );
    }
    finish(mc, id, &input);
}

fn extension(mc: &mut FakeMc) {
    mc.on_shape("gitAction", |mc, id, shape| {
        run(mc, id, shape["input"].clone());
        Ok(())
    });
    mc.on_rpc("vcs.refreshStatus", |mc, rpc| {
        {
            let git = mc.part::<FakeCheckout>();
            if git.outside_change {
                git.outside_change = false;
                git.changed.push("README.md".into());
            }
        }
        send_status(mc);
        mc.reply(rpc, Json::Null);
        Ok(())
    });
    mc.on_rpc("vcs.pull", |mc, rpc| {
        let refuse = mc.part::<FakeCheckout>().refuse_pull.clone();
        if !refuse.is_empty() {
            mc.refuse(rpc, &refuse);
            return Ok(());
        }
        let (reference, pulled, remote_name) = {
            let git = mc.part::<FakeCheckout>();
            let pulled = git.behind > 0;
            git.pulled += git.behind;
            git.behind = 0;
            (git.branch_name(), pulled, git.remote_name.clone())
        };
        send_status(mc);
        mc.reply(
            rpc,
            json!({"status": if pulled { "pulled" } else { "skipped_up_to_date" },
                   "refName": reference,
                   "upstreamRef": format!("{remote_name}/{reference}")}),
        );
        Ok(())
    });
    mc.on_rpc("vcs.init", |mc, rpc| {
        let refuse = mc.part::<FakeCheckout>().refuse_init.clone();
        if !refuse.is_empty() {
            mc.refuse(rpc, &refuse);
            return Ok(());
        }
        {
            let git = mc.part::<FakeCheckout>();
            git.initialized = true;
            git.is_repo = true;
            git.has_remote = false;
            git.upstream = false;
        }
        send_status(mc);
        mc.reply(rpc, Json::Null);
        Ok(())
    });
    mc.on_rpc("sourceControl.publishRepository", |mc, rpc| {
        mc.part::<FakeCheckout>()
            .publishes
            .push(rpc.payload.clone());
        let refuse = mc.part::<FakeCheckout>().refuse_publish.clone();
        if !refuse.is_empty() {
            mc.refuse(rpc, &refuse);
            return Ok(());
        }
        let repository = text(&rpc.payload["repository"]);
        let remote_name = text(&rpc.payload["remoteName"]);
        let branch = {
            let git = mc.part::<FakeCheckout>();
            git.has_remote = true;
            git.upstream = true;
            git.remote_name = remote_name.clone();
            let ahead = std::mem::take(&mut git.ahead);
            git.remote
                .entry(format!("{remote_name}/{}", git.branch_name()))
                .or_default()
                .extend(ahead);
            git.branch_name()
        };
        send_status(mc);
        mc.reply(
            rpc,
            json!({"repository": {"nameWithOwner": repository,
                                  "url": format!("https://github.com/{repository}")},
                   "remoteName": remote_name, "branch": branch, "status": "pushed"}),
        );
        Ok(())
    });
}

fn fake(world: &mut World) -> &mut FakeCheckout {
    world.mc.part::<FakeCheckout>()
}

fn git(world: &World) -> Json {
    world.state("git")
}

fn menu_entry(world: &World, label: &str) -> Json {
    git(world)["menu"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|item| item["label"] == label)
        .cloned()
        .unwrap_or(Json::Null)
}

fn toast_titled(world: &World, title: &str) -> Json {
    world.state("toasts")["items"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|item| item["title"] == title)
        .cloned()
        .unwrap_or(Json::Null)
}

fn dispatch(world: &mut World, action: &str, payload: Json) -> Outcome {
    world.dispatch(action, payload)?;
    world.sync()
}

/// The checkout as the MC now has it, once the header shows it.
fn settle(world: &mut World) -> Outcome {
    send_status(&mut world.mc);
    world.sync()
}

/// Waits for the actions sent so far to finish.
fn await_idle(world: &mut World) -> Outcome {
    world.wait_for_with(
        |w| git(w)["busy"].as_bool() != Some(true),
        |w| format!("the git actions to finish; they are {}", show(&git(w))),
    )?;
    world.sync()
}

/// A feature branch level with its upstream, nothing changed.
fn clean(git: &mut FakeCheckout) {
    git.known = true;
    git.is_repo = true;
    git.branch = Some("feature/tax".into());
    git.has_remote = true;
    git.upstream = true;
    git.ahead.clear();
    git.behind = 0;
    git.ahead_of_default = None;
    git.changed.clear();
    git.pr = false;
}

fn on_default_branch(git: &mut FakeCheckout, branch: &str) {
    git.default_branch = branch.into();
    git.branch = Some(branch.into());
    git.upstream = true;
    git.ahead = vec!["Tidy the cart".into()];
    if git.changed.is_empty() {
        git.changed = vec!["src/cart.ts".into()];
    }
}

/// The project's folder becomes the checkout the fake reports.
fn checkout_of(world: &mut World, project: &str) {
    let cwd = format!("/work/{project}");
    fake(world).cwd = cwd.clone();
    world.mc.checkouts.insert(
        cwd.clone(),
        Rc::new(|mc: &mut FakeMc| {
            let git = mc.part::<FakeCheckout>();
            json!({"local": git.local(), "remote": git.remote_status()})
        }),
    );
    world.mc.projects.insert(
        project.to_owned(),
        json!({"id": project, "title": project, "workspaceRoot": cwd, "scripts": []}),
    );
}

/// A thread of `project` on the fake's checkout, open, on an MC that is
/// connected (now, or already).
fn open_thread_in(world: &mut World, project: &str) -> Outcome {
    checkout_of(world, project);
    let thread = json!({
        "id": THREAD, "title": "Tax line", "projectId": project, "branch": "feature/tax",
        "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"});
    world.mc.threads.insert(THREAD.into(), thread.clone());
    if world.shell_subscriptions() == 0 {
        world.connect()?;
    } else {
        let row = world.mc.projects[project].clone();
        world.mc.send_row_of(project, &row, "project");
        world.mc.send_row(THREAD, &thread);
        world.sync()?;
    }
    let key = format!("{}:{THREAD}", world.mc.environment_id);
    world.with::<Navigation, _>(|n, engine| n.open(engine, Route::Thread(key)))?;
    world.wait_for_with(
        |w| git(w)["available"].as_bool() == Some(true),
        |w| format!("the git actions to show; they are {}", show(&git(w))),
    )
}

/// The git actions as the GitActions brick draws them, with its dialogs.
fn git_brick(world: &mut World) -> Outcome<Brick> {
    if world.part::<Shown>().0.is_none() {
        Brick::show(
            world,
            "import QtQuick\nimport HalC2.Bricks\nGitActions {}\n",
            900.0,
            700.0,
        )?;
    }
    shown(world)
}

/// `fakeGitRepo`'s sibling every steps file reaches for: the fake's files.
fn file_paths(git: &Json) -> Vec<String> {
    git["files"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|f| text(&f["path"]))
        .collect()
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);

    steps.step(
        &format!(
            "a connected environment with a thread in the git project {Q}(?: with the remote {Q})?"
        ),
        |world, c, _| {
            if !c[1].is_empty() {
                fake(world).remote_name = c[1].clone();
            }
            open_thread_in(world, &c[0])
        },
    );
    // status-and-changes.feature and repository-discovery-clone-publish.feature.
    steps.step(
        &format!("a connected environment with the project {Q} in a git repository"),
        |world, c, _| {
            checkout_of(world, &c[0]);
            world.connect()?;
            world.sync()
        },
    );
    steps.step(
        "the agent's turn ends after editing a file",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    let g = git(w);
                    g["available"].as_bool() == Some(true) && file_paths(&g).is_empty()
                },
                |w| format!("a clean checkout; the git actions are {}", show(&git(w))),
            )?;
            // The MC watches the checkout and says what changed (vcs/watch.ex).
            fake(world).changed = vec!["src/cart.ts".into()];
            settle(world)
        },
    );
    steps.step(
        "the thread's status shows the new change without the user asking for a refresh",
        |world, _, _| {
            world.wait_for_with(
                |w| file_paths(&git(w)) == ["src/cart.ts"],
                |w| format!("the change to show; the git actions are {}", show(&git(w))),
            )?;
            let g = git(world);
            expect!(
                text(at(&g, "quickAction.label")).starts_with("Commit"),
                "the git actions are {}",
                show(&g)
            );
            expect!(
                world
                    .mc
                    .calls
                    .iter()
                    .all(|rpc| rpc.method != "vcs.refreshStatus"),
                "the shell asked the MC to refresh"
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the project {Q} is not in a git repository"),
        |world, c, _| {
            clean(fake(world));
            fake(world).is_repo = false;
            open_thread_in(world, &c[0])?;
            world.wait_for_with(
                |w| git(w)["isRepo"] == json!(false),
                |w| {
                    format!(
                        "Initialize Git to be on offer; the git actions are {}",
                        show(&git(w))
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the user initializes Git for {Q}"),
        |world, c, _| {
            expect!(
                world.state("workspace")["projectTitle"] == c[0].as_str(),
                "the thread is not in {}",
                c[0]
            );
            dispatch(world, "git.init", Json::Null)
        },
    );
    steps.step(&format!("{Q} becomes a git repository"), |world, c, _| {
        world.wait_for_with(
            |w| {
                let g = git(w);
                w.mc.peek::<FakeCheckout>().is_some_and(|f| f.initialized)
                    && g["isRepo"] == json!(true)
                    && g["initPending"].as_bool() != Some(true)
            },
            |w| format!("the git actions are {}", show(&git(w))),
        )?;
        let cwd = format!("/work/{}", c[0]);
        let asked = world
            .mc
            .calls
            .iter()
            .any(|rpc| rpc.method == "vcs.init" && rpc.payload["cwd"] == cwd.as_str());
        expect!(asked, "the MC was not asked to initialize {}", c[0]);
        Ok(())
    });
    steps.step(
        &format!("the git actions for {Q} become available"),
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    let g = git(w);
                    g["available"].as_bool() == Some(true)
                        && g["menu"].as_array().is_some_and(|m| !m.is_empty())
                },
                |w| format!("the git actions; they are {}", show(&git(w))),
            )?;
            expect!(
                !menu_entry(world, "Commit").is_null(),
                "the git menu is {}",
                show(&git(world)["menu"])
            );
            Ok(())
        },
    );

    // Publishing (repository-discovery-clone-publish.feature), through the
    // brick's dialog.
    steps.step(
        &format!("the project {Q} has (?:commits and )?no remote"),
        |world, c, _| {
            {
                let git = fake(world);
                clean(git);
                git.has_remote = false;
                git.upstream = false;
                git.ahead = vec!["Add notes".into()];
            }
            open_thread_in(world, &c[0])?;
            world.wait_for_with(
                |w| at(&git(w), "quickAction.kind") == "open_publish",
                |w| {
                    format!(
                        "Publish repository to be recommended; the git actions are {}",
                        show(&git(w))
                    )
                },
            )
        },
    );
    steps.step(
        "the user chooses to publish the repository",
        |world, _, _| dispatch(world, "git.quick", Json::Null),
    );
    steps.step(&format!("publishing begins for {Q}"), |world, c, _| {
        world.wait_for_with(
            |w| git(w)["publishing"].is_object(),
            |w| {
                format!(
                    "the publish dialog to open; the git actions are {}",
                    show(&git(w))
                )
            },
        )?;
        expect!(
            world.state("workspace")["projectTitle"] == c[0].as_str()
                && fake(world).publishes.is_empty(),
            "publishing is not for {}",
            c[0]
        );
        let brick = git_brick(world)?;
        let mut drawn = false;
        world.wait_for_with(
            |w| {
                drawn = brick.shows(w, "Publish repository").unwrap_or(false)
                    && brick.shows(w, "Step 1 of 3 · Host").unwrap_or(false);
                drawn
            },
            |_| "the publish dialog to be drawn".into(),
        )
    });
    steps.step("the user publishes the repository", |world, _, _| {
        git_brick(world)?;
        dispatch(world, "git.quick", Json::Null)?;
        world.wait_for_with(
            |w| git(w)["publishing"]["hosts"][0]["ready"].as_bool() == Some(true),
            |w| {
                format!(
                    "the hosts to be known; the git actions are {}",
                    show(&git(w))
                )
            },
        )
    });
    steps.step(
        "the user picks a host, names the repository, picks its visibility and confirms a summary",
        |world, _, _| {
            let brick = git_brick(world)?;
            let on_step = |world: &mut World, label: &str| {
                world.wait_for_with(
                    |w| brick.shows(w, label).unwrap_or(false),
                    |_| format!("the dialog to reach \"{label}\""),
                )
            };
            // The host.
            on_step(world, "Step 1 of 3 · Host")?;
            let host = brick.item(world, "publishHost")?;
            expect!(
                brick.text_of(world, host, "currentValue") == "github",
                "GitHub is not the host offered first"
            );
            brick.click(world, "publishNext")?;
            // The repository and its visibility: no name, no next step.
            on_step(world, "Step 2 of 3 · Repository")?;
            let next = brick.item(world, "publishNext")?;
            expect!(
                !brick.flag(world, next, "enabled"),
                "a repository with no name can be published"
            );
            brick.click(world, "publishRepository")?;
            for ch in "acme/notes".chars() {
                brick.press(world, &ch.to_string())?;
            }
            let visibility = brick.item(world, "publishVisibility")?;
            brick.write(world, visibility, "currentIndex", Value::from(1))?;
            brick.click(world, "publishNext")?;
            // The summary; nothing is published until it is confirmed.
            on_step(world, "Step 3 of 3 · Summary")?;
            let summary_item = brick.item(world, "publishSummary")?;
            let summary = brick.text_of(world, summary_item, "text");
            expect!(
                summary
                    == "Create the public repository acme/notes on GitHub, add it as the remote origin and push feature/tax.",
                "the summary reads \"{summary}\""
            );
            expect!(
                fake(world).publishes.is_empty(),
                "the repository was published before the summary was confirmed"
            );
            // Back and forth keeps what was entered.
            brick.click(world, "publishBack")?;
            on_step(world, "Step 2 of 3 · Repository")?;
            brick.click(world, "publishNext")?;
            on_step(world, "Step 3 of 3 · Summary")?;
            brick.click(world, "publishConfirm")?;
            world.wait_for_with(
                |w| git(w)["publishing"].is_null(),
                |w| format!("the publish dialog to close; the git actions are {}", show(&git(w))),
            )?;
            let publishes = fake(world).publishes.clone();
            expect!(
                publishes.len() == 1,
                "the MC was asked to publish {} times",
                publishes.len()
            );
            let input = &publishes[0];
            expect!(
                input["repository"] == "acme/notes"
                    && input["visibility"] == "public"
                    && input["provider"] == "github"
                    && input["cwd"] == "/work/notes",
                "the MC was asked {}",
                show(input)
            );
            Ok(())
        },
    );
    steps.step("the GitHub CLI is not signed in", |world, _, _| {
        // `gh` is installed and has no account (SourceControlProviderDiscoveryItem).
        world.mc.on_rpc("server.discoverSourceControl", |mc, rpc| {
            let none = json!({"_tag": "None"});
            mc.reply(
                rpc,
                json!({"versionControlSystems": [],
                       "sourceControlProviders": [{
                           "kind": "github", "label": "GitHub", "executable": "gh",
                           "status": "available",
                           "installHint": "Install GitHub and make sure `gh` is on the PATH.",
                           "version": none,
                           "auth": {"status": "unauthenticated", "account": none,
                                    "host": none, "detail": none}}]}),
            );
            Ok(())
        });
        Ok(())
    });
    steps.step("the user picks GitHub to publish to", |world, _, _| {
        // A repository with nothing published yet.
        {
            let git = fake(world);
            clean(git);
            git.has_remote = false;
            git.upstream = false;
            git.ahead = vec!["Add notes".into()];
        }
        open_thread_in(world, "notes")?;
        let brick = git_brick(world)?;
        dispatch(world, "git.publish", Json::Null)?;
        world.wait_for_with(
            |w| brick.shows(w, "Step 1 of 3 · Host").unwrap_or(false),
            |_| "the publish dialog to be drawn".into(),
        )?;
        let host = brick.item(world, "publishHost")?;
        brick.write(world, host, "currentIndex", Value::from(0))?;
        expect!(
            brick.text_of(world, host, "currentText") == "GitHub",
            "GitHub is not offered"
        );
        Ok(())
    });
    steps.step(
        "the user is told GitHub is not authenticated and how to fix it",
        |world, _, _| {
            let brick = git_brick(world)?;
            world.wait_for_with(
                |w| brick.shows(w, NOT_AUTHENTICATED).unwrap_or(false),
                |w| format!("the host's hint; the git actions are {}", show(&git(w))),
            )?;
            // And it goes no further.
            let next = brick.item(world, "publishNext")?;
            expect!(
                !brick.flag(world, next, "enabled"),
                "a host that is not signed in can be published to"
            );
            expect!(
                fake(world).publishes.is_empty(),
                "the MC was asked to publish"
            );
            Ok(())
        },
    );

    // The checkout's states.
    type State = (&'static str, fn(&mut FakeCheckout));
    let states: Vec<State> = vec![
        ("has uncommitted changes and no remote", |g| {
            g.changed = vec!["src/cart.ts".into()];
            g.has_remote = false;
            g.upstream = false;
        }),
        ("has uncommitted changes on the default branch", |g| {
            g.changed = vec!["src/cart.ts".into()];
            g.branch = Some(g.default_branch.clone());
        }),
        (
            "has uncommitted changes on a branch with an open pull request",
            |g| {
                g.changed = vec!["src/cart.ts".into()];
                g.pr = true;
            },
        ),
        (
            "has uncommitted changes on a feature branch with a remote",
            |g| g.changed = vec!["src/cart.ts".into()],
        ),
        ("has uncommitted changes", |g| {
            g.changed = vec!["src/cart.ts".into()];
            g.ahead_of_default = Some(1);
        }),
        ("has commits on a feature branch with no upstream", |g| {
            g.upstream = false;
            g.ahead = vec!["Add tax".into()];
        }),
        ("is behind its upstream", |g| {
            g.behind = 2;
            g.ahead_of_default = Some(1);
        }),
        ("is ahead of its upstream with an open pull request", |g| {
            g.ahead = vec!["Add tax".into()];
            g.pr = true;
        }),
        (
            "is pushed and ahead of the default branch with no pull request",
            |g| g.ahead_of_default = Some(2),
        ),
        ("is up to date with an open pull request", |g| g.pr = true),
        ("has no status yet", |g| g.known = false),
        ("has diverged from its upstream", |g| {
            g.ahead = vec!["Add tax".into()];
            g.behind = 1;
        }),
        ("is up to date with nothing to do", |g| {
            g.ahead_of_default = Some(0)
        }),
        ("has no upstream and no local commits", |g| {
            g.upstream = false
        }),
        ("has no uncommitted changes", |_| {}),
        ("is on a detached HEAD with changes", |g| {
            g.branch = None;
            g.changed = vec!["src/cart.ts".into()];
        }),
        ("has commits and no remote", |g| {
            g.has_remote = false;
            g.upstream = false;
            g.ahead = vec!["Add tax".into()];
        }),
        ("'s branch has an open pull request", |g| g.pr = true),
        (" is not a repository", |g| g.is_repo = false),
    ];
    for (state, apply) in states {
        let sep = if state.starts_with('\'') || state.starts_with(' ') {
            ""
        } else {
            " "
        };
        steps.step(
            &format!("the checkout{sep}{}", fancy_regex::escape(state)),
            move |world, _, _| {
                clean(fake(world));
                apply(fake(world));
                settle(world)
            },
        );
    }
    steps.step(
        "the checkout is running another git action",
        |world, _, _| {
            {
                let git = fake(world);
                clean(git);
                git.changed = vec!["src/cart.ts".into()];
                git.wait_after_hook = true;
            }
            settle(world)?;
            dispatch(world, "git.quick", Json::Null)
        },
    );
    steps.step(
        "the checkout changed outside HAL-C2 a moment ago",
        |world, _, _| {
            clean(fake(world));
            settle(world)?;
            fake(world).outside_change = true;
            Ok(())
        },
    );
    steps.step(
        "the project's primary remote is on (GitHub|GitLab)",
        |world, c, _| {
            {
                let git = fake(world);
                clean(git);
                git.provider = c[0].to_lowercase();
                git.ahead_of_default = Some(2);
            }
            settle(world)
        },
    );
    steps.step(
        &format!("the checkout is on the default branch {Q}"),
        |world, c, _| {
            on_default_branch(fake(world), &c[0]);
            settle(world)
        },
    );

    // Looking.
    steps.step(
        "the user looks at the thread's git actions",
        |world, _, _| world.sync(),
    );
    steps.step(&format!("the recommended action is {Q}"), |world, c, _| {
        let label = c[0].clone();
        world.wait_for_with(
            |w| {
                let action = &git(w)["quickAction"];
                action["label"] == label.as_str() && action["disabledReason"].is_null()
            },
            |w| {
                format!(
                    "the recommended action to be {}; the git actions are {}",
                    c[0],
                    show(&git(w))
                )
            },
        )
    });
    steps.step("the recommended action is unavailable", |world, _, _| {
        world.wait_for_with(
            |w| !at(&git(w), "quickAction.disabledReason").is_null(),
            |w| {
                format!(
                    "the recommended action to be unavailable; the git actions are {}",
                    show(&git(w))
                )
            },
        )
    });
    steps.step(&format!("the reason given is {Q}"), |world, c, _| {
        let g = git(world);
        expect!(
            at(&g, "quickAction.disabledReason") == c[0].as_str(),
            "the git actions are {}",
            show(&g)
        );
        Ok(())
    });
    steps.step(
        "pushing and opening a pull request are unavailable",
        |world, _, _| {
            for label in ["Push", "Create PR"] {
                let entry = menu_entry(world, label);
                expect!(
                    !entry.is_null() && !entry["disabledReason"].is_null(),
                    "the git menu is {}",
                    show(&git(world)["menu"])
                );
            }
            Ok(())
        },
    );
    steps.step(
        "the user is told to create and check out a branch first",
        |world, _, _| {
            let state = git(world);
            let hinted = state["hints"].as_array().is_some_and(|h| {
                h.iter().any(|x| {
                    x == "Detached HEAD: check out a branch to push or open a pull request."
                })
            });
            expect!(
                at(&state, "quickAction.disabledReason")
                    == "Create and checkout a ref before pushing or opening a pull request."
                    && hinted,
                "the git actions are {}",
                show(&state)
            );
            Ok(())
        },
    );
    steps.step(
        "the git menu offers only committing and publishing",
        |world, _, _| {
            let state = git(world);
            let menu = state["menu"].as_array().cloned().unwrap_or_default();
            expect!(
                menu.len() == 1
                    && menu[0]["id"] == "commit"
                    && state["canPublish"].as_bool() == Some(true),
                "the git actions are {}",
                show(&state)
            );
            Ok(())
        },
    );
    steps.step("the user opens the git menu", |world, _, _| {
        dispatch(world, "git.refresh", Json::Null)
    });
    steps.step(
        "the menu reflects the checkout as it is now",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    let entry = menu_entry(w, "Commit");
                    !entry.is_null() && entry["disabledReason"].is_null()
                },
                |w| {
                    format!(
                        "Commit to be on offer; the git menu is {}",
                        show(&git(w)["menu"])
                    )
                },
            )
        },
    );
    steps.step(&format!("{Q} is unavailable because {Q}"), |world, c, _| {
        let entry = menu_entry(world, &c[0]);
        expect!(
            entry["disabledReason"] == c[1].as_str(),
            "the git menu is {}",
            show(&git(world)["menu"])
        );
        Ok(())
    });
    steps.step(
        &format!("the pull request entry is called {Q}"),
        |world, c, _| {
            world.wait_for_with(
                |w| !menu_entry(w, &c[0]).is_null(),
                |w| format!("the git menu is {}", show(&git(w)["menu"])),
            )
        },
    );
    steps.step(
        "the user chooses to view the pull request",
        |world, _, _| dispatch(world, "git.quick", Json::Null),
    );
    steps.step("the pull request opens on its host", |world, _, _| {
        let opened = world.opened_urls();
        expect!(
            opened.iter().any(|u| u == PR_URL),
            "the browser opened {opened:?}"
        );
        Ok(())
    });

    // Pushing and pulling.
    steps.step(
        &format!("{Q} tracks {Q} and is (\\d+) commits? ahead"),
        |world, c, _| {
            {
                let git = fake(world);
                clean(git);
                git.branch = Some(c[0].clone());
                for n in 0..c[2].parse::<usize>().unwrap_or(0) {
                    git.ahead.push(format!("Commit {}", n + 1));
                }
            }
            settle(world)
        },
    );
    steps.step("the user pushes", |world, _, _| {
        dispatch(world, "git.menu", json!({"id": "push"}))?;
        await_idle(world)
    });
    steps.step(&format!("{Q} has the new commit"), |world, c, _| {
        let git = fake(world);
        let held = git.remote.get(&c[0]).cloned().unwrap_or_default();
        expect!(
            held.len() == 1 && git.ahead.is_empty(),
            "{} holds {}",
            c[0],
            held.join(", ")
        );
        Ok(())
    });
    steps.step(
        "the user is told where the branch was pushed",
        |world, _, _| {
            let title = {
                let git = fake(world);
                format!("Pushed to {}/{}", git.remote_name, git.branch_name())
            };
            world.wait_for_with(
                |w| !toast_titled(w, &title).is_null(),
                |w| {
                    format!(
                        "the toast {title}; the shell shows {}",
                        show(&w.state("toasts"))
                    )
                },
            )
        },
    );
    steps.step("a push finishes", |world, _, _| {
        {
            let git = fake(world);
            clean(git);
            git.ahead = vec!["Add tax".into()];
        }
        settle(world)?;
        dispatch(world, "git.menu", json!({"id": "push"}))?;
        await_idle(world)
    });
    steps.step("the user is told what was pushed", |world, _, _| {
        world.wait_for_with(
            |w| toast_titled(w, "Pushed to origin/feature/tax")["type"] == "success",
            |w| {
                format!(
                    "the push's result; the shell shows {}",
                    show(&w.state("toasts"))
                )
            },
        )
    });
    steps.step(
        "the message goes away by itself after a while",
        |world, _, _| {
            // Toasts expire on the engine's clock, which set_time leaves.
            world.set_time(world.now() + Duration::seconds(11));
            world.advance(11_000)?;
            world.sync()?;
            expect!(
                toast_titled(world, "Pushed to origin/feature/tax").is_null(),
                "the shell shows {}",
                show(&world.state("toasts"))
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} is (\\d+) commits behind its upstream and has no local commits"),
        |world, c, _| {
            {
                let git = fake(world);
                clean(git);
                git.branch = Some(c[0].clone());
                git.behind = c[1].parse().unwrap_or(0);
            }
            settle(world)
        },
    );
    steps.step("the user pulls", |world, _, _| {
        world.wait_for_with(
            |w| at(&git(w), "quickAction.label") == "Pull",
            |w| format!("Pull to be on offer; the git actions are {}", show(&git(w))),
        )?;
        dispatch(world, "git.quick", Json::Null)?;
        await_idle(world)
    });
    steps.step("the branch has the (\\d+) new commits", |world, c, _| {
        let expected: i64 = c[0].parse().unwrap_or(0);
        let git = fake(world);
        expect!(
            git.pulled == expected && git.behind == 0,
            "the pull brought in {}",
            git.pulled
        );
        world.wait_for_with(
            |w| !toast_titled(w, "Pulled").is_null(),
            |w| {
                format!(
                    "the toast Pulled; the shell shows {}",
                    show(&w.state("toasts"))
                )
            },
        )
    });

    // The default branch.
    steps.step(&format!("the user runs {Q}"), |world, c, _| {
        // An action of the planner plugin when the MC runs it comes first.
        if super::planner::run_plugin_action(world, &c[0])? {
            return Ok(());
        }
        world.sync()?;
        // From an open command palette: its entry of that title.
        let row = world.with::<hal_c2_shell::controllers::palette::Palette, _>(|p, _| {
            if !p.is_open() {
                return None;
            }
            let found =
                (0..p.count()).find(|row| p.shown_at(*row).is_some_and(|(title, _)| title == c[0]));
            Some(found)
        })?;
        if let Some(found) = row {
            let Some(row) = found else {
                fail!("the command palette does not list \"{}\"", c[0]);
            };
            // `act` refreshes the palette's props, which a controller call leaves stale.
            super::palette::act(world, |p, engine| p.run(engine, row))?;
            return world.sync();
        }
        // A keybinding command by its id ("terminal.new"), as a key or a
        // rice runs it.
        let engine = world.engine().clone();
        let commands = hal_c2_shell::commands::Commands::of(&engine);
        if commands.contains(&engine, &c[0]) {
            commands.run(&engine, &c[0]);
            return world.sync();
        }
        if at(&git(world), "quickAction.label") == c[0].as_str() {
            return dispatch(world, "git.quick", Json::Null);
        }
        // A pull request is offered for committed work only.
        if c[0] == "Create PR" && !fake(world).changed.is_empty() {
            fake(world).changed.clear();
            settle(world)?;
        }
        let entry = menu_entry(world, &c[0]);
        expect!(
            !entry.is_null() && entry["disabledReason"].is_null(),
            "the git actions are {}",
            show(&git(world))
        );
        dispatch(world, "git.menu", json!({"id": entry["id"]}))
    });
    steps.step(
        &format!("the user is asked to confirm before anything reaches {Q}"),
        |world, c, _| {
            let pending = git(world)["pendingDefaultBranch"].clone();
            let ran = fake(world).inputs.len();
            expect!(
                text(&pending["description"]).contains(&format!("\"{}\"", c[0])) && ran == 0,
                "the git actions are {}, and the MC ran {ran}",
                show(&git(world))
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user was asked to confirm pushing to {Q}"),
        |world, c, _| {
            {
                let git = fake(world);
                on_default_branch(git, &c[0]);
                git.changed.clear();
            }
            settle(world)?;
            dispatch(world, "git.menu", json!({"id": "push"}))?;
            expect!(
                !git(world)["pendingDefaultBranch"].is_null(),
                "the git actions are {}",
                show(&git(world))
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user was asked to confirm committing and pushing to {Q}"),
        |world, c, _| {
            on_default_branch(fake(world), &c[0]);
            settle(world)?;
            dispatch(world, "git.quick", Json::Null)?;
            expect!(
                at(&git(world), "pendingDefaultBranch.title") == "Commit & push to default ref?",
                "the git actions are {}",
                show(&git(world))
            );
            Ok(())
        },
    );
    fn choose(world: &mut World, choice: &str) -> Outcome {
        dispatch(world, "git.defaultBranch", json!({"choice": choice}))?;
        await_idle(world)
    }
    steps.step("the user continues", |world, _, _| {
        choose(world, "continue")
    });
    steps.step("the user aborts", |world, _, _| choose(world, "abort"));
    steps.step(
        "the user chooses to create a feature branch and continue",
        |world, _, _| choose(world, "featureBranch"),
    );
    steps.step(&format!("the push runs against {Q}"), |world, c, _| {
        let git = fake(world);
        let target = format!("{}/{}", git.remote_name, c[0]);
        let held = git.remote.get(&target).cloned().unwrap_or_default();
        expect!(
            git.inputs.len() == 1 && held.len() == 1,
            "{target} holds {}",
            held.join(", ")
        );
        Ok(())
    });
    steps.step("nothing is committed or pushed", |world, _, _| {
        let ran = fake(world).inputs.len();
        expect!(
            ran == 0 && git(world)["pendingDefaultBranch"].is_null(),
            "the MC ran {ran} actions; the git actions are {}",
            show(&git(world))
        );
        Ok(())
    });
    steps.step(
        &format!("the work is committed on a new branch and pushed there instead of {Q}"),
        |world, c, _| {
            let checkout = fake(world);
            let last = checkout.commits.last();
            let ok = last.is_some_and(|commit| {
                commit.branch.starts_with("feature/")
                    && checkout
                        .remote
                        .get(&format!("{}/{}", checkout.remote_name, commit.branch))
                        .is_some_and(|held| held.contains(&commit.subject))
                    && !checkout
                        .remote
                        .contains_key(&format!("{}/{}", checkout.remote_name, c[0]))
            });
            expect!(
                ok,
                "the commit is on {} and the remote holds {}",
                last.map(|l| l.branch.clone()).unwrap_or_default(),
                checkout
                    .remote
                    .keys()
                    .cloned()
                    .collect::<Vec<_>>()
                    .join(", ")
            );
            Ok(())
        },
    );

    // Committing.
    steps.step(
        &format!("the user has changed {Q} and {Q}"),
        |world, c, _| {
            fake(world).changed = vec![c[0].clone(), c[1].clone()];
            settle(world)
        },
    );
    fn commit(world: &mut World, payload: Json) -> Outcome {
        world.wait_for_with(
            |w| menu_entry(w, "Commit")["disabledReason"].is_null(),
            |w| {
                format!(
                    "Commit to be on offer; the git actions are {}",
                    show(&git(w))
                )
            },
        )?;
        dispatch(world, "git.commit", payload)?;
        // A slow hook leaves the action running for the scenario to watch.
        if !fake(world).wait_while_writing {
            await_idle(world)?;
        }
        Ok(())
    }
    steps.step(
        &format!("the user commits with the message {Q}"),
        |world, c, _| commit(world, json!({"message": c[0], "filePaths": null})),
    );
    steps.step(
        "the user commits without writing a message",
        |world, _, _| commit(world, json!({"message": "  ", "filePaths": null})),
    );
    steps.step(
        &format!("the user leaves {Q} out of the commit and commits"),
        |world, c, _| {
            let mut picked = fake(world).changed.clone();
            picked.retain(|f| *f != c[0]);
            commit(
                world,
                json!({"message": "Add the cart", "filePaths": picked}),
            )
        },
    );
    steps.step(
        &format!("the user commits on a new branch with the message {Q}"),
        |world, c, _| {
            commit(
                world,
                json!({"message": c[0], "filePaths": null, "featureBranch": true}),
            )
        },
    );
    steps.step(&format!("a commit {Q} holds both files"), |world, c, _| {
        let commits = &fake(world).commits;
        expect!(
            commits.len() == 1 && commits[0].subject == c[0] && commits[0].files.len() == 2,
            "the MC made {} commits: {}",
            commits.len(),
            commits
                .first()
                .map(|x| x.subject.clone())
                .unwrap_or_default()
        );
        Ok(())
    });
    steps.step(
        "the user is told the commit was made with its short hash",
        |world, _, _| {
            let sha = fake(world)
                .commits
                .last()
                .map(|c| c.sha.chars().take(7).collect::<String>())
                .unwrap_or_default();
            let title = format!("Committed {sha}");
            world.wait_for_with(
                |w| toast_titled(w, &title)["type"] == "success",
                |w| {
                    format!(
                        "the toast {title}; the shell shows {}",
                        show(&w.state("toasts"))
                    )
                },
            )
        },
    );
    steps.step(
        "the writer model writes the commit message from the staged diff",
        |world, _, _| {
            let git = fake(world);
            expect!(
                git.inputs
                    .last()
                    .is_some_and(|i| i.get("commitMessage").is_none()),
                "the MC was asked {}",
                git.inputs.first().map(show).unwrap_or_default()
            );
            Ok(())
        },
    );
    steps.step("the commit is made with that message", |world, _, _| {
        let git = fake(world);
        expect!(
            git.commits.len() == 1 && git.commits[0].subject == git.generated_message,
            "the MC made {} commits",
            git.commits.len()
        );
        Ok(())
    });
    steps.step(&format!("the commit holds only {Q}"), |world, c, _| {
        let git = fake(world);
        expect!(
            git.commits.len() == 1 && git.commits[0].files == [c[0].clone()],
            "the commit holds {}",
            git.commits
                .first()
                .map(|x| x.files.join(", "))
                .unwrap_or_default()
        );
        Ok(())
    });
    steps.step(
        &format!("{Q} is still changed in the working tree"),
        |world, c, _| {
            world.wait_for_with(
                |w| file_paths(&git(w)) == [c[0].clone()],
                |w| format!("the changed files are {}", show(&git(w)["files"])),
            )
        },
    );
    steps.step(
        &format!("a branch named after the message under {Q} is created and checked out"),
        |world, c, _| {
            let branch = fake(world).branch_name();
            expect!(
                branch.starts_with(&c[0]) && branch.contains("add-tax"),
                "the checkout is on {branch}"
            );
            world.wait_for_with(
                |w| text(&w.mc.threads[THREAD]["branch"]) == branch,
                |w| {
                    format!(
                        "the thread to be on {branch}; it is on {}",
                        text(&w.mc.threads[THREAD]["branch"])
                    )
                },
            )
        },
    );
    steps.step("the commit is made on that branch", |world, _, _| {
        let git = fake(world);
        expect!(
            git.commits.len() == 1 && git.commits[0].branch == git.branch_name(),
            "the commit is on {}",
            git.commits
                .first()
                .map(|x| x.branch.clone())
                .unwrap_or_default()
        );
        Ok(())
    });

    // Progress, results, pulling, init, publishing and links.
    steps.step(
        &format!("the pre-commit hook prints {Q} and waits"),
        |world, c, _| {
            let git = fake(world);
            git.hook_line = c[0].clone();
            git.wait_after_hook = true;
            Ok(())
        },
    );
    steps.step(
        &format!("the user starts committing with the message {Q}"),
        |world, c, _| {
            dispatch(
                world,
                "git.commit",
                json!({"message": c[0], "filePaths": null}),
            )
        },
    );
    steps.step("the hook finishes", |world, _, _| {
        let (id, input) = {
            let git = fake(world);
            let Some(id) = git.held else {
                fail!("no action is waiting");
            };
            git.wait_after_hook = false;
            git.held = None;
            (id, git.inputs.last().cloned().unwrap_or(Json::Null))
        };
        finish(&mut world.mc, id, &input);
        await_idle(world)
    });
    // The commit review (GitActions' dialog), as the git menu's Commit opens it.
    fn start_commit(world: &mut World) -> Outcome<ljos::prelude::ObjectId> {
        let brick = git_brick(world)?;
        let dialog = brick.item(world, "commitDialog")?;
        world.wait_for("the changed files to be listed", |w| {
            git(w)["files"].as_array().is_some_and(|f| !f.is_empty())
        })?;
        for method in ["reset", "open"] {
            world
                .engine()
                .invoke_by_name(dialog, method, &[])
                .map_err(|e| crate::harness::Failure(format!("{method}: {e:?}")))?;
        }
        world.wait_for_with(
            |w| brick.flag(w, dialog, "opened"),
            |_| "the commit review to open".into(),
        )?;
        Ok(dialog)
    }
    steps.step("the user starts a commit", |world, _, _| {
        start_commit(world).map(|_| ())
    });
    steps.step(
        &format!("the user opens {Q} from the commit review"),
        |world, c, _| {
            super::workspace::have_editor(world, &c[0])?;
            start_commit(world)?;
            shown(world)?.click(world, &format!("fileOpen-{}", c[0]))?;
            world.sync()
        },
    );
    steps.step(
        "the user leaves every file out of the commit",
        |world, _, _| {
            start_commit(world)?;
            let brick = shown(world)?;
            for path in fake(world).changed.clone() {
                brick.click(world, &format!("fileCheck-{path}"))?;
            }
            Ok(())
        },
    );
    steps.step(
        "neither committing nor committing on a new branch is possible",
        |world, _, _| {
            let brick = git_brick(world)?;
            world.wait_for_with(
                |w| {
                    let selected = brick.item(w, "commitSelected");
                    let branch = brick.item(w, "commitNewBranch");
                    match (selected, branch) {
                        (Ok(s), Ok(b)) => {
                            !brick.flag(w, s, "enabled") && !brick.flag(w, b, "enabled")
                        }
                        _ => false,
                    }
                },
                |_| "Commit and Commit on new branch to be unavailable".into(),
            )?;
            let ran = fake(world).inputs.len();
            expect!(ran == 0, "the MC ran {ran} actions");
            // The reverse: a file put back makes committing possible again.
            let first = fake(world).changed.first().cloned().unwrap_or_default();
            brick.click(world, &format!("fileCheck-{first}"))?;
            world.wait_for_with(
                |w| {
                    brick
                        .item(w, "commitSelected")
                        .is_ok_and(|s| brick.flag(w, s, "enabled"))
                },
                |_| "Commit to be available again".into(),
            )
        },
    );
    steps.step(
        "the user starts a commit and then cancels it",
        |world, _, _| {
            let dialog = start_commit(world)?;
            let brick = shown(world)?;
            brick.click(world, "commitCancel")?;
            world.wait_for_with(
                |w| !brick.flag(w, dialog, "opened"),
                |_| "the commit review to close".into(),
            )?;
            world.sync()
        },
    );
    steps.step(
        "nothing is committed and both files are still changed",
        |world, _, _| {
            let (ran, commits, changed) = {
                let git = fake(world);
                (git.inputs.len(), git.commits.len(), git.changed.len())
            };
            let files = file_paths(&git(world)).len();
            expect!(
                ran == 0 && commits == 0 && changed == 2 && files == 2,
                "the MC ran {ran} actions; the git actions are {}",
                show(&git(world))
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user is warned that the commit lands on {Q}"),
        |world, c, _| {
            let warning = format!("Warning: committing on the default branch {}", c[0]);
            let brick = shown(world)?;
            world.wait_for_with(
                |w| brick.shows(w, &warning).unwrap_or(false),
                |_| format!("the warning \"{warning}\""),
            )
        },
    );

    // A running action's stage, elapsed time and hook line (`git.progress`),
    // as the pill draws them.
    steps.step(
        "the repository has a slow pre-commit hook",
        |world, _, _| {
            let git = fake(world);
            git.hook_line = "lint: 12 files checked".into();
            git.wait_while_writing = true;
            git.wait_after_hook = true;
            Ok(())
        },
    );
    steps.step(
        &format!("the user sees {Q} and then {Q} with the elapsed time"),
        |world, c, _| {
            let progress = |w: &World| git(w)["progress"].clone();
            world.wait_for_with(
                |w| progress(w)["stage"] == c[0].as_str() && progress(w)["elapsed"] == "0s",
                |w| {
                    format!(
                        "the action to say {}; the git actions are {}",
                        c[0],
                        show(&git(w))
                    )
                },
            )?;
            Brick::show(
                world,
                "import QtQuick\nimport HalC2.Bricks\nGitActions {}\n",
                900.0,
                200.0,
            )?;
            let brick = shown(world)?;
            let first = format!("{} 0s", c[0]);
            world.wait_for_with(
                |w| brick.shows(w, &first).unwrap_or(false),
                |_| format!("the pill to say \"{first}\""),
            )?;
            // Five seconds on, the message is written and the hook runs. The
            // elapsed time is the engine's clock, which set_time leaves.
            world.set_time(world.now() + Duration::seconds(5));
            world.advance(5000)?;
            let (id, input, hook) = {
                let checkout = fake(world);
                let Some(id) = checkout.held else {
                    fail!("no action is waiting");
                };
                checkout.wait_while_writing = false;
                checkout.held = None;
                let input = checkout.inputs.pop().unwrap_or(Json::Null);
                (id, input, checkout.hook_line.clone())
            };
            // run() picks the action up where it waited.
            phase(&world.mc, id, "commit", "Committing...");
            send_event(
                &world.mc,
                id,
                json!({"kind": "hook_started", "hookName": "pre-commit"}),
            );
            send_event(
                &world.mc,
                id,
                json!({"kind": "hook_output", "hookName": "pre-commit", "stream": "stdout",
                       "text": format!("lint: starting\n{hook}\n")}),
            );
            let checkout = fake(world);
            checkout.inputs.push(input);
            checkout.held = Some(id);
            world.wait_for_with(
                |w| progress(w)["stage"] == c[1].as_str() && progress(w)["elapsed"] == "5s",
                |w| {
                    format!(
                        "the action to say {} after 5s; the git actions are {}",
                        c[1],
                        show(&git(w))
                    )
                },
            )?;
            let second = format!("{} 5s", c[1]);
            world.wait_for_with(
                |w| brick.shows(w, &second).unwrap_or(false),
                |_| format!("the pill to say \"{second}\""),
            )
        },
    );
    steps.step("the last line the hook printed", |world, _, _| {
        let line = fake(world).hook_line.clone();
        expect!(
            at(&git(world), "progress.hookLine") == line.as_str(),
            "the git actions are {}",
            show(&git(world))
        );
        expect!(
            toast_titled(world, "Committing...")["description"] == line.as_str(),
            "the shell shows {}",
            show(&world.state("toasts"))
        );
        // Once the hook is done the action finishes and the progress goes.
        let (id, input) = {
            let checkout = fake(world);
            checkout.wait_after_hook = false;
            (
                checkout.held.take(),
                checkout.inputs.last().cloned().unwrap_or(Json::Null),
            )
        };
        finish(&mut world.mc, id.unwrap_or_default(), &input);
        await_idle(world)?;
        expect!(
            git(world)["progress"].is_null(),
            "the git actions are {}",
            show(&git(world))
        );
        Ok(())
    });

    // A failure stays until the user closes it (errors.feature).
    steps.step("the push will be rejected by the remote", |world, _, _| {
        {
            let git = fake(world);
            clean(git);
            git.ahead = vec!["Add tax".into()];
            git.fail_with = "remote: rejected (non-fast-forward)".into();
            git.fail_phase = "push".into();
        }
        settle(world)
    });
    steps.step(
        "the failure stays visible until the user dismisses it",
        |world, _, _| {
            let failure = |w: &World| toast_titled(w, "Action failed");
            world.wait_for_with(
                |w| failure(w)["type"] == "error",
                |w| format!("the failure; the shell shows {}", show(&w.state("toasts"))),
            )?;
            expect!(
                failure(world)["description"] == "remote: rejected (non-fast-forward)",
                "the failure reads {}",
                show(&failure(world))
            );
            // Long after a result would have gone away by itself.
            // Toasts expire on the engine's clock, which set_time leaves.
            world.set_time(world.now() + Duration::seconds(3600));
            world.advance(3_600_000)?;
            world.sync()?;
            expect!(!failure(world).is_null(), "the failure went away by itself");
            dispatch(
                world,
                "notification.dismiss",
                json!({"id": failure(world)["id"]}),
            )?;
            expect!(
                failure(world).is_null(),
                "the shell still shows {}",
                show(&world.state("toasts"))
            );
            Ok(())
        },
    );

    // A refusal the MC knows the remedy of (errors.feature).
    steps.step(
        &format!("the push will be refused, offering {Q} to (open|copy) {Q}"),
        |world, c, _| {
            {
                let git = fake(world);
                clean(git);
                git.ahead = vec!["Add tax".into()];
                git.fail_with = "git push failed: refused".into();
                git.fail_phase = "push".into();
                let opens = c[1] == "open";
                let mut cta = Map::new();
                cta.insert(
                    "kind".into(),
                    json!(if opens { "open_url" } else { "copy_command" }),
                );
                cta.insert("label".into(), json!(c[0]));
                cta.insert(if opens { "url" } else { "command" }.into(), json!(c[2]));
                git.fail_cta = Json::Object(cta);
            }
            settle(world)
        },
    );
    steps.step(
        &format!("the user chooses {Q} on the failure"),
        |world, c, _| {
            world.wait_for_with(
                |w| !toast_titled(w, "Action failed").is_null(),
                |w| format!("the failure; the shell shows {}", show(&w.state("toasts"))),
            )?;
            let failure = toast_titled(world, "Action failed");
            for action in failure["actions"].as_array().into_iter().flatten() {
                if action["label"] != c[0].as_str() {
                    continue;
                }
                return dispatch(
                    world,
                    "notification.action",
                    json!({"id": failure["id"], "actionId": action["id"]}),
                );
            }
            fail!("the failure is {}", show(&failure))
        },
    );
    steps.step("the failure is still shown", |world, _, _| {
        expect!(
            !toast_titled(world, "Action failed").is_null(),
            "the shell shows {}",
            show(&world.state("toasts"))
        );
        Ok(())
    });

    steps.step(
        &format!("the MC fails the action with {Q}"),
        |world, c, _| {
            fake(world).fail_with = c[0].clone();
            Ok(())
        },
    );
    steps.step(
        &format!("the MC refuses to pull with {Q}"),
        |world, c, _| {
            fake(world).refuse_pull = c[0].clone();
            Ok(())
        },
    );
    steps.step(
        &format!("the MC refuses to initialize Git with {Q}"),
        |world, c, _| {
            fake(world).refuse_init = c[0].clone();
            Ok(())
        },
    );
    steps.step(
        &format!("the MC refuses to publish with {Q}"),
        |world, c, _| {
            fake(world).refuse_publish = c[0].clone();
            Ok(())
        },
    );
    steps.step("the user runs the recommended action", |world, _, _| {
        dispatch(world, "git.quick", Json::Null)?;
        await_idle(world)
    });
    steps.step("the git actions offer to initialize Git", |world, _, _| {
        world.wait_for_with(
            |w| git(w)["isRepo"] == json!(false),
            |w| {
                format!(
                    "Initialize Git to be on offer; the git actions are {}",
                    show(&git(w))
                )
            },
        )
    });
    steps.step("the user initializes Git", |world, _, _| {
        dispatch(world, "git.init", Json::Null)
    });
    steps.step("the checkout is a repository", |world, _, _| {
        world.wait_for_with(
            |w| {
                let g = git(w);
                w.mc.peek::<FakeCheckout>().is_some_and(|f| f.initialized)
                    && g["isRepo"] == json!(true)
                    && g["initPending"].as_bool() != Some(true)
            },
            |w| format!("the git actions are {}", show(&git(w))),
        )
    });
    steps.step("the publish dialog is open", |world, _, _| {
        world.wait_for_with(
            |w| git(w)["publishing"].is_object(),
            |w| {
                format!(
                    "the publish dialog to open; the git actions are {}",
                    show(&git(w))
                )
            },
        )
    });
    steps.step("the publish dialog is closed", |world, _, _| {
        world.wait_for_with(
            |w| git(w)["publishing"].is_null(),
            |w| {
                format!(
                    "the publish dialog to close; the git actions are {}",
                    show(&git(w))
                )
            },
        )
    });
    steps.step(
        &format!("the user publishes {Q} as a (private|public) (GitHub|GitLab) repository"),
        |world, c, _| {
            dispatch(
                world,
                "git.publish.submit",
                json!({"repository": c[0], "visibility": c[1], "provider": c[2].to_lowercase()}),
            )
        },
    );
    steps.step("the user cancels publishing", |world, _, _| {
        dispatch(world, "git.publish.cancel", Json::Null)
    });
    steps.step(
        &format!("the MC published {Q} to {Q} as (private|public) on (github|gitlab)"),
        |world, c, _| {
            let publishes = fake(world).publishes.clone();
            expect!(
                publishes.len() == 1,
                "the MC was asked to publish {} times",
                publishes.len()
            );
            let input = &publishes[0];
            expect!(
                input["repository"] == c[0].as_str()
                    && input["remoteName"] == c[1].as_str()
                    && input["visibility"] == c[2].as_str()
                    && input["provider"] == c[3].as_str(),
                "the MC was asked {}",
                show(input)
            );
            Ok(())
        },
    );
    steps.step("nothing is published", |world, _, _| {
        expect!(
            fake(world).publishes.is_empty(),
            "the MC was asked to publish"
        );
        Ok(())
    });
    steps.step(&format!("the publish dialog says {Q}"), |world, c, _| {
        world.wait_for_with(
            |w| {
                let g = git(w);
                at(&g, "publishing.error") == c[0].as_str()
                    && at(&g, "publishing.busy").as_bool() != Some(true)
            },
            |w| format!("the git actions are {}", show(&git(w))),
        )
    });
    steps.step("the MC is asked to push", |world, _, _| {
        await_idle(world)?;
        let last = fake(world).inputs.last().cloned();
        expect!(
            last.as_ref().is_some_and(|i| i["action"] == "push"),
            "the MC was asked {}",
            last.as_ref().map(show).unwrap_or_default()
        );
        Ok(())
    });
    // Threads on another machine of the cluster.
    steps.step(&format!("the action ran on {Q}"), |world, c, _| {
        let mut environment = String::new();
        for sub in &world.mc.subscriptions {
            let shape = &sub["shape"];
            if shape["type"] == "gitAction" {
                environment = text(&shape["environment"]);
            }
        }
        expect!(
            environment == c[0],
            "the last action ran on \"{environment}\""
        );
        Ok(())
    });
    steps.step("the git actions are available again", |world, _, _| {
        world.wait_for_with(
            |w| {
                let g = git(w);
                g["available"].as_bool() == Some(true) && g["unavailableReason"].is_null()
            },
            |w| format!("the git actions are {}", show(&git(w))),
        )
    });
    steps.step(&format!("the git actions say {Q}"), |world, c, _| {
        world.wait_for_with(
            |w| {
                let g = git(w);
                g["unavailableReason"] == c[0].as_str() && g["available"].as_bool() != Some(true)
            },
            |w| format!("the git actions are {}", show(&git(w))),
        )
    });

    // navigation/layout.feature: the header's git pill (GitActions) over the
    // git state.
    steps.step(
        "the user opens the git actions from the header",
        |world, _, _| dispatch(world, "git.refresh", Json::Null),
    );
    steps.step("the thread's git actions are offered", |world, _, _| {
        world.wait_for_with(
            |w| {
                let g = git(w);
                g["available"].as_bool() == Some(true)
                    && g["menu"].as_array().is_some_and(|m| !m.is_empty())
            },
            |w| {
                format!(
                    "the header's git actions; the git state is {}",
                    show(&git(w))
                )
            },
        )
    });
}

// Unused Rpc import guard for handlers that name the type.
#[allow(dead_code)]
fn _rpc(_: &Rpc) {}
