//! The right panel's Pull requests tab (ThreadPullRequests): the pull requests
//! linked to a thread, from its shell row, and linking, unlinking and
//! refreshing them as the MC does (apps/server-ex orchestration.ex
//! thread.pull-request.link/unlink, pull_requests.ex invalidate); and the
//! Pull request review tab (PullRequestReview): what GitHub holds of pull
//! request 42 as the MC reads it (pull_requests.ex detail, activity,
//! files_viewed, comment, submit_review, set_thread_resolution) and its code
//! over HTTP in two slices (router.ex POST /api/pull-requests/diff).
//! features/source-control/pull-request-threads.feature and
//! pull-request-review.feature: desktop-qt's PullRequestSteps.cpp.

use std::collections::{BTreeSet, HashMap};
use std::rc::Rc;

use hal_c2_shell::commands::Commands;
use hal_c2_shell::controllers::navigation::Navigation;
use hal_c2_shell::controllers::panel::RightPanel;
use hal_c2_shell::thread_view::diff::DiffModel;
use hal_c2_shell::thread_view::pull_request_review::{PullRequestReview, Review};
use hal_c2_shell::thread_view::pull_requests::{PullRequests, ThreadPullRequests};
use hal_c2_shell::thread_view::rows::RowSource;
use ljos::prelude::ObjectId;
use serde_json::{Value, json};

use super::stream::{FakeStreams, PROJECT, THREAD, add_item, look, settle_run, start_run};
use crate::brick::{Brick, shown};
use crate::fake_mc::{FakeMc, Rpc};
use crate::harness::{Failure, Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

/// What GitHub holds of each pull request ("acme/shop#42"), the thread the
/// scenario is about, and the pull requests the MC was asked to read again.
pub struct FakePullRequests {
    pub host: HashMap<String, Value>,
    pub thread: String,
    pub invalidated: Vec<Value>,
    /// The host's stack: its base and its layers' numbers, bottom first.
    pub stack_base: String,
    pub stack: Vec<i64>,
}

impl Default for FakePullRequests {
    fn default() -> FakePullRequests {
        let host = HashMap::from([
            (
                "acme/shop#42".to_owned(),
                json!({"state": "open", "title": "Tax line fix", "headBranch": "feature/tax",
                       "baseBranch": "main", "isDraft": false, "author": "ada",
                       "additions": 12, "deletions": 3, "reviewDecision": "review-required",
                       "checksState": "passing", "mergeability": "mergeable",
                       "syncedAt": "2026-09-23T09:00:00Z"}),
            ),
            (
                "acme/api#7".to_owned(),
                json!({"state": "open", "title": "Tax API", "headBranch": "tax",
                       "baseBranch": "main", "isDraft": false, "author": "ada",
                       "checksState": "pending", "syncedAt": "2026-09-23T09:00:00Z"}),
            ),
        ]);
        FakePullRequests {
            host,
            thread: String::new(),
            invalidated: Vec::new(),
            stack_base: String::new(),
            stack: Vec::new(),
        }
    }
}

fn host_key(reference: &Value) -> String {
    format!(
        "{}#{}",
        text(&reference["repository"]),
        reference["number"].as_i64().unwrap_or(0)
    )
}

/// The thread's links, each with what the host last said of it: the MC's sync.
pub fn sync_links(mc: &mut FakeMc, thread_id: &str) {
    let Some(mut row) = mc.threads.get(thread_id).cloned() else {
        return;
    };
    let mut links = Vec::new();
    for mut link in row["pullRequests"].as_array().cloned().unwrap_or_default() {
        let fake = mc.part::<FakePullRequests>();
        link["snapshot"] = fake
            .host
            .get(&host_key(&link))
            .cloned()
            .unwrap_or(Value::Null);
        // A layer of the host's stack carries the stack (pull_requests/sync.ex).
        if fake.stack.contains(&link["number"].as_i64().unwrap_or(0)) {
            let layers: Vec<Value> = fake
                .stack
                .iter()
                .map(|n| json!({"number": n, "headBranch": format!("stack/{n}"), "state": "open"}))
                .collect();
            link["stack"] = json!({"kind": "native", "id": "stack-1", "number": 1,
                                   "url": "https://github.com/acme/shop/stacks/1",
                                   "base": fake.stack_base, "layers": layers});
        }
        links.push(link);
    }
    row["pullRequests"] = Value::Array(links);
    mc.threads.insert(thread_id.to_owned(), row.clone());
    mc.send_row(thread_id, &row);
}

fn extension(mc: &mut FakeMc) {
    mc.effects.push(Rc::new(|mc, command| {
        let kind = text(&command["type"]);
        if kind != "thread.pull-request.link" && kind != "thread.pull-request.unlink" {
            return;
        }
        let thread_id = text(&command["threadId"]);
        let mut row = mc.threads.get(&thread_id).cloned().unwrap_or(Value::Null);
        let mut links = Vec::new();
        let mut known = false;
        for link in row["pullRequests"].as_array().cloned().unwrap_or_default() {
            let same = host_key(&link) == host_key(command) && link["host"] == command["host"];
            known = known || same;
            if !(same && kind == "thread.pull-request.unlink") {
                links.push(link);
            }
        }
        if kind == "thread.pull-request.link" && !known {
            links.push(
                json!({"host": command["host"], "repository": command["repository"],
                              "number": command["number"], "url": command["url"],
                              "source": command["source"], "linkedAt": "2026-09-23T09:05:00Z",
                              "snapshot": null, "stack": null}),
            );
        }
        row["pullRequests"] = Value::Array(links);
        mc.threads.insert(thread_id.clone(), row);
        // The MC reads a new link from its host at once (Sync.request).
        sync_links(mc, &thread_id);
    }));
    // The workspace's checkout status: a snapshot of a faked checkout, else nothing yet.
    mc.on_shape("vcs", |mc, id, shape| {
        let cwd = text(&shape["cwd"]);
        if let Some(status) = mc.checkouts.get(&cwd).cloned() {
            let status = status(mc);
            mc.send(&json!({"t": "vcs", "id": id,
                            "event": {"_tag": "snapshot", "local": status["local"],
                                      "remote": status["remote"]}}));
        }
        Ok(())
    });
    mc.on_rpc("pullRequests.invalidate", |mc, rpc| {
        // The pull requests page's refresh names no reference (pull_request_list.rs).
        if rpc.payload.get("reference").is_none() {
            return mc.pass_on(rpc);
        }
        mc.part::<FakePullRequests>()
            .invalidated
            .push(rpc.payload["reference"].clone());
        let thread = mc.part::<FakePullRequests>().thread.clone();
        sync_links(mc, &thread);
        mc.reply(rpc, Value::Null);
        Ok(())
    });
}

fn tab_object(world: &World) -> Outcome<ObjectId> {
    world
        .with::<RightPanel, _>(|p, _| p.pull_requests())?
        .ok_or_else(|| Failure("the panel has no Pull requests tab".into()))
}

pub fn read_tab<R>(world: &World, f: impl FnOnce(&PullRequests) -> R) -> Outcome<R> {
    let obj = tab_object(world)?;
    ThreadPullRequests::read(world.engine(), obj, f)
        .ok_or_else(|| Failure("the Pull requests tab is busy".into()))
}

fn update_tab<R>(world: &World, f: impl FnOnce(&mut PullRequests) -> R) -> Outcome<R> {
    let obj = tab_object(world)?;
    ThreadPullRequests::update(world.engine(), obj, f)
        .ok_or_else(|| Failure("the Pull requests tab is gone".into()))
}

fn role_text(tab: &PullRequests, row: usize, role: &str) -> String {
    tab.data(row, role).to_js_string().to_string()
}

pub fn describe(world: &World) -> String {
    read_tab(world, |tab| {
        let rows: Vec<String> = (0..tab.row_count())
            .map(|row| {
                format!(
                    "{} \"{}\" {}/{}/{}",
                    role_text(tab, row, "linkKey"),
                    role_text(tab, row, "title"),
                    role_text(tab, row, "stateLabel"),
                    role_text(tab, row, "checksLabel"),
                    role_text(tab, row, "reviewLabel"),
                )
            })
            .collect();
        format!(
            "the tab lists {} ({}, problem \"{}\")",
            if rows.is_empty() {
                "nothing".to_owned()
            } else {
                rows.join("; ")
            },
            if tab.online() { "online" } else { "offline" },
            tab.problem()
        )
    })
    .unwrap_or_else(|f| f.0)
}

pub fn row_of(world: &World, number: i64) -> Option<usize> {
    read_tab(world, |tab| {
        (0..tab.row_count()).find(|&row| match tab.data(row, "number") {
            ljos::prelude::Value::Int(n) => i64::from(n) == number,
            _ => false,
        })
    })
    .ok()
    .flatten()
}

/// The link key ("github.com/acme/shop#42") of pull request `number`.
pub fn key_of(world: &World, number: i64) -> Outcome<String> {
    let Some(row) = row_of(world, number) else {
        fail!("{}", describe(world));
    };
    read_tab(world, |tab| role_text(tab, row, "linkKey"))
}

pub fn wait_for_row(world: &mut World, number: i64, listed: bool) -> Outcome {
    world.wait_for_with(
        move |w| row_of(w, number).is_some() == listed,
        |w| describe(w),
    )
}

fn row_role(world: &World, number: i64, role: &str) -> String {
    row_of(world, number)
        .and_then(|row| read_tab(world, |tab| role_text(tab, row, role)).ok())
        .unwrap_or_default()
}

/// The thread the scenario is about, in "acme/shop", looked at with its Pull
/// requests tab showing.
pub fn look_at(world: &mut World, title: &str) -> Outcome {
    if !world.mc.part::<FakePullRequests>().thread.is_empty() {
        return Ok(());
    }
    world.mc.part::<FakePullRequests>().thread = THREAD.into();
    let row = json!({"id": THREAD, "title": title, "projectId": PROJECT,
                     "pullRequests": [],
                     "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"});
    world.mc.threads.insert(THREAD.into(), row.clone());
    world.mc.send_row(THREAD, &row);
    world.sync()?;
    let environment = world.mc.environment_id.clone();
    let streams = world.mc.part::<FakeStreams>();
    streams.thread = THREAD.into();
    streams.environment = environment.clone();
    look(world, &format!("{environment}:{THREAD}"), true)?;
    world.dispatch("rightPanel.add", json!({"kind": "pull-requests"}))?;
    world.sync()?;
    let panel = world.state("panel");
    expect!(
        at(&panel, "activeId") == "pull-requests",
        "{}",
        show(&panel)
    );
    Ok(())
}

/// As "Link pull request to thread" from the palette: the tab with its field open.
pub fn link(world: &mut World, input: &str) -> Outcome {
    world.with::<RightPanel, _>(|p, engine| p.link_pull_request(engine))?;
    expect!(
        read_tab(world, PullRequests::link_open)?,
        "the link field is closed"
    );
    let obj = tab_object(world)?;
    ThreadPullRequests::link(world.engine(), obj, input);
    world.sync()
}

fn set_online(world: &mut World, online: bool) -> Outcome {
    let id = world.mc.subscribers("shell").first().copied().unwrap_or(0);
    world
        .mc
        .send(&json!({"t": "shell.mc", "id": id, "mc": world.mc.name, "online": online}));
    world.sync()?;
    world.wait_for_with(
        move |w| read_tab(w, PullRequests::online).is_ok_and(|o| o == online),
        |w| describe(w),
    )
}

// The Pull request review tab.

/// What the host and the viewer hold of pull request 42's review.
#[derive(Default)]
struct FakeReview {
    author: String,
    comments: Vec<Value>,
    threads: Vec<Value>,
    viewed: BTreeSet<String>,
    refuse_viewed: bool,
    /// Every change asked of the host, by method.
    sent: Vec<String>,
    slices: usize,
    /// What the host says of the pull request, and whether the viewer may merge it.
    state: Option<String>,
    write_access: bool,
    /// Every `pullRequests.runAction` input.
    actions: Vec<Value>,
    /// The stack cannot be read from the host now, and how often it was asked.
    stack_fails: bool,
    stack_reads: usize,
}

const CART_PATCH: &str = "diff --git a/src/cart.ts b/src/cart.ts\n--- a/src/cart.ts\n+++ b/src/cart.ts\n@@ -1,2 +1,2 @@\n const total = 0;\n-const tax = 1;\n+const tax = 2;\n";
const TAX_PATCH: &str = "diff --git a/src/tax.ts b/src/tax.ts\n--- a/src/tax.ts\n+++ b/src/tax.ts\n@@ -1 +1,2 @@\n export const rate = 0.2;\n+export const reduced = 0.1;\n";

fn actor(login: &str) -> Value {
    json!({"login": login, "name": null, "avatarUrl": null})
}

fn remark(id: String, kind: &str, body: &Value, at: &str, state: Value) -> Value {
    json!({"id": id, "kind": kind, "author": actor("me"), "body": body,
           "createdAt": at, "reviewState": state})
}

/// Answers the review's reads and changes the way the MC does.
fn serve_review(mc: &mut FakeMc) {
    mc.on_rpc("pullRequests.detail", |mc, rpc| {
        let stacked = !mc.part::<FakePullRequests>().stack.is_empty();
        let fake = mc.part::<FakeReview>();
        let state = fake.state.clone().unwrap_or_else(|| "open".into());
        let actions = if fake.write_access || stacked {
            json!(["merge", "close"])
        } else {
            json!([])
        };
        let author = actor(&fake.author);
        mc.reply(
            rpc,
            json!({
                "repository": "acme/shop",
                "number": rpc.payload["number"],
                "title": "Tax line fix",
                "body": "Rounds the tax line.",
                "url": "https://github.com/acme/shop/pull/42",
                "author": author,
                "state": state,
                "isDraft": false,
                // GitHub merges three ways; the repository allows them all.
                "capabilities": {"actions": ["merge", "close"],
                                 "mergeMethods": ["merge", "squash", "rebase"]},
                "mergeCapabilities": {"merge": true, "squash": true, "rebase": true},
                // A stack is its author's to merge and rebase.
                "viewerPermissions": {"actions": actions, "stackRebase": true},
                "mergeability": "mergeable",
                "headBranch": "feature/tax",
                "baseBranch": "main",
                "behindBy": 2,
                "reviewers": [actor("ada")],
                "labels": [{"name": "tax"}],
                "checks": [{"name": "test", "status": "success", "description": null, "url": null}],
            }),
        );
        Ok(())
    });
    mc.on_rpc("pullRequests.activity", |mc, rpc| {
        let fake = mc.part::<FakeReview>();
        let answer = json!({"comments": fake.comments, "commentCount": fake.comments.len(),
                            "commentsTruncated": false, "reviewThreads": fake.threads,
                            "commits": []});
        mc.reply(rpc, answer);
        Ok(())
    });
    mc.on_rpc("pullRequests.filesViewed", |mc, rpc| {
        let files: Vec<Value> = mc
            .part::<FakeReview>()
            .viewed
            .iter()
            .map(|path| json!({"path": path, "state": "viewed"}))
            .collect();
        mc.reply(rpc, json!({"files": files, "truncated": false}));
        Ok(())
    });
    mc.on_rpc("pullRequests.setFilesViewed", |mc, rpc| {
        let fake = mc.part::<FakeReview>();
        fake.sent.push(rpc.method.clone());
        if fake.refuse_viewed {
            mc.refuse(rpc, "GitHub did not accept the viewed mark.");
            return Ok(());
        }
        for file in rpc.payload["files"].as_array().cloned().unwrap_or_default() {
            let path = text(&file["path"]);
            if file["viewed"].as_bool() == Some(true) {
                fake.viewed.insert(path);
            } else {
                fake.viewed.remove(&path);
            }
        }
        mc.reply(rpc, Value::Null);
        Ok(())
    });
    mc.on_rpc("pullRequests.comment", |mc, rpc| {
        let fake = mc.part::<FakeReview>();
        fake.sent.push(rpc.method.clone());
        let id = format!("c{}", fake.comments.len() + 1);
        fake.comments.push(remark(
            id,
            "comment",
            &rpc.payload["body"],
            "2026-09-23T10:00:00Z",
            Value::Null,
        ));
        mc.reply(rpc, Value::Null);
        Ok(())
    });
    mc.on_rpc("pullRequests.submitReview", |mc, rpc| {
        let fake = mc.part::<FakeReview>();
        fake.sent.push(rpc.method.clone());
        let state = match text(&rpc.payload["verdict"]).as_str() {
            "approve" => "APPROVED",
            "request-changes" => "CHANGES_REQUESTED",
            _ => "COMMENTED",
        };
        let id = format!("r{}", fake.comments.len() + 1);
        fake.comments.push(remark(
            id,
            "review",
            &rpc.payload["body"],
            "2026-09-23T10:01:00Z",
            json!(state),
        ));
        mc.reply(rpc, Value::Null);
        Ok(())
    });
    // The host's stack, as `pullRequests.stack` reads it: every layer with the head it has now.
    mc.on_rpc("pullRequests.stack", |mc, rpc| {
        let (base, stack) = {
            let pulls = mc.part::<FakePullRequests>();
            (pulls.stack_base.clone(), pulls.stack.clone())
        };
        let fake = mc.part::<FakeReview>();
        fake.stack_reads += 1;
        if fake.stack_fails {
            mc.refuse(rpc, "GitHub could not be reached.");
            return Ok(());
        }
        if !stack.contains(&rpc.payload["number"].as_i64().unwrap_or(0)) {
            mc.reply(rpc, Value::Null);
            return Ok(());
        }
        let layers: Vec<Value> = stack
            .iter()
            .map(|n| {
                json!({"number": n, "title": format!("Layer {n}"), "isDraft": false,
                       "headSha": format!("sha-{n}"), "headBranch": format!("stack/{n}"),
                       "state": "open"})
            })
            .collect();
        mc.reply(
            rpc,
            json!({"id": "stack-1", "number": 1,
                   "url": "https://github.com/acme/shop/stacks/1", "base": base,
                   "layers": layers}),
        );
        Ok(())
    });
    mc.on_rpc("pullRequests.runAction", |mc, rpc| {
        let fake = mc.part::<FakeReview>();
        fake.sent.push(rpc.method.clone());
        fake.actions.push(rpc.payload.clone());
        if !fake.write_access && rpc.payload.get("stackNumber").is_none() {
            mc.refuse(
                rpc,
                "You do not have permission to merge this pull request.",
            );
            return Ok(());
        }
        if rpc.payload["action"] == "merge" {
            fake.state = Some("merged".into());
        }
        mc.reply(rpc, Value::Null);
        Ok(())
    });
    mc.on_rpc("pullRequests.setThreadResolution", |mc, rpc| {
        let fake = mc.part::<FakeReview>();
        fake.sent.push(rpc.method.clone());
        for thread in &mut fake.threads {
            if thread["id"] == rpc.payload["threadId"] {
                thread["isResolved"] = rpc.payload["resolved"].clone();
            }
        }
        mc.reply(rpc, Value::Null);
        Ok(())
    });
    mc.on_http("/api/pull-requests/diff", |mc, body, respond| {
        mc.part::<FakeReview>().slices += 1;
        let first = body.get("cursor").is_none();
        respond.send(
            200,
            &json!({"patch": if first { CART_PATCH } else { TAX_PATCH },
                    "truncated": false,
                    "nextCursor": if first { json!("2") } else { Value::Null }}),
        );
        Ok(())
    });
}

fn review_object(world: &World) -> Outcome<ObjectId> {
    world
        .with::<RightPanel, _>(|p, _| p.review())?
        .ok_or_else(|| Failure("the panel has no review tab".into()))
}

fn read_review<R>(world: &World, f: impl FnOnce(&Review) -> R) -> Outcome<R> {
    let obj = review_object(world)?;
    PullRequestReview::read(world.engine(), obj, f)
        .ok_or_else(|| Failure("the review is busy".into()))
}

fn update_review<R>(world: &World, f: impl FnOnce(&mut Review) -> R) -> Outcome<R> {
    let obj = review_object(world)?;
    PullRequestReview::update(world.engine(), obj, f)
        .ok_or_else(|| Failure("the review is gone".into()))
}

fn code<R>(
    world: &World,
    f: impl FnOnce(&hal_c2_shell::thread_view::diff::Diff) -> R,
) -> Outcome<R> {
    let obj = review_object(world)?;
    let Some(model) = PullRequestReview::model(world.engine(), obj) else {
        fail!("the review has no code");
    };
    DiffModel::read(world.engine(), model, f).ok_or_else(|| Failure("the code is busy".into()))
}

fn viewed_count(world: &World) -> usize {
    let paths = code(world, |d| d.paths()).unwrap_or_default();
    read_review(world, |r| r.viewed_of(&paths).len()).unwrap_or(0)
}

fn describe_review(world: &World) -> String {
    let files = code(world, |d| {
        (0..d.file_count())
            .map(|file| {
                format!(
                    "{}{}",
                    d.path(file).unwrap_or(""),
                    if d.expanded(file) { "" } else { " (collapsed)" }
                )
            })
            .collect::<Vec<_>>()
            .join(", ")
    })
    .unwrap_or_default();
    read_review(world, |r| {
        format!(
            "the review of {} is {} \"{}\" ({}), \"{}\", {} remarks, {} threads, code {} [{}], {} viewed, problem \"{}\"",
            r.key(),
            r.status(),
            r.message(),
            if r.online() { "online" } else { "offline" },
            text(&r.detail()["title"]),
            r.conversation().len(),
            r.review_threads().len(),
            r.code_status(),
            files,
            viewed_count(world),
            r.problem()
        )
    })
    .unwrap_or_else(|f| f.0)
}

fn expanded(world: &World, path: &str) -> bool {
    code(world, |d| {
        d.file_of(path).is_some_and(|file| d.expanded(file))
    })
    .unwrap_or(false)
}

fn open_review(world: &mut World, number: i64) -> Outcome {
    let key = key_of(world, number)?;
    world.dispatch("rightPanel.review", json!({"key": key}))?;
    world.sync()?;
    let panel = world.state("panel");
    expect!(
        at(&panel, "activeId") == &json!(format!("pull-request:{key}")),
        "{}",
        show(&panel)
    );
    world.wait_for_with(
        |w| {
            read_review(w, |r| r.status() == "ready" && r.code_status() == "ready").unwrap_or(false)
        },
        |w| describe_review(w),
    )
}

fn review_thread(world: &World) -> Outcome<Value> {
    match read_review(world, |r| r.review_threads().first().cloned())? {
        Some(thread) => Ok(thread),
        None => fail!("{}", describe_review(world)),
    }
}

/// Shows the review panel's brick over the open review.
fn show_review(world: &mut World, width: f64, height: f64) -> Outcome<Brick> {
    Brick::show(
        world,
        "import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\nPullRequestReviewPanel { source: Panel.review; anchors.fill: parent }\n",
        width,
        height,
    )?;
    shown(world)
}

/// The stack in the pull request's review, and its actions, which ask first.
fn review_stack(world: &mut World, number: i64) -> Outcome<Brick> {
    world.mc.part::<FakeReview>().author = "octocat".into();
    serve_review(&mut world.mc);
    look_at(world, "Tax work")?;
    if row_of(world, number).is_none() {
        link(world, &number.to_string())?;
    }
    wait_for_row(world, number, true)?;
    open_review(world, number)?;
    world.wait_for_with(
        |w| read_review(w, |r| r.stack()["size"].as_i64() == Some(3)).unwrap_or(false),
        |w| {
            format!(
                "the stack; it is {}",
                show(&read_review(w, |r| r.stack()).unwrap_or_default())
            )
        },
    )?;
    let brick = show_review(world, 700.0, 800.0)?;
    world.wait_for("the review to show the stack", move |w| {
        brick
            .shows(w, "Stack #1 · layer 2 of 3 onto main")
            .unwrap_or(false)
    })?;
    Ok(brick)
}

fn stack_of(world: &World) -> Value {
    read_review(world, Review::stack).unwrap_or_default()
}

fn actions(world: &mut World) -> Vec<Value> {
    world.mc.part::<FakeReview>().actions.clone()
}

fn asked(world: &World, method: &str) -> Vec<Value> {
    world
        .mc
        .calls
        .iter()
        .filter(|rpc: &&Rpc| rpc.method == method)
        .map(|rpc| rpc.payload.clone())
        .collect()
}

fn link_row(number: i64, source: &str) -> Value {
    json!({"host": "github.com", "repository": "acme/shop", "number": number,
           "url": format!("https://github.com/acme/shop/pull/{number}"),
           "source": source, "linkedAt": "2026-09-23T09:05:00Z",
           "snapshot": null, "stack": null})
}

/// Puts `link` on the thread's row, as the MC's sync reads it from the host.
fn put_link(world: &mut World, number: i64) -> Outcome {
    let mut row = world.mc.threads.get(THREAD).cloned().unwrap_or(Value::Null);
    row["pullRequests"] = json!([link_row(number, "manual")]);
    world.mc.threads.insert(THREAD.into(), row);
    sync_links(&mut world.mc, THREAD);
    world.sync()
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);

    steps.step(
        &format!("a connected environment with the GitHub project {Q}"),
        |world, c, _| {
            world.mc.projects.insert(
                PROJECT.into(),
                json!({"id": PROJECT, "title": PROJECT, "workspaceRoot": format!("/work/{PROJECT}"),
                       "scripts": [],
                       "repositoryIdentity": {"canonicalKey": format!("github.com/{}", c[0]),
                                              "displayName": c[0]}}),
            );
            world.connect()?;
            world.sync()
        },
    );
    steps.step(
        &format!("the environment also has the Azure DevOps project {Q}"),
        |world, c, _| {
            let id = "azure-web";
            let row = json!({"id": id, "title": id, "workspaceRoot": format!("/work/{id}"),
                             "scripts": [],
                             "repositoryIdentity": {"canonicalKey": c[0]}});
            world.mc.projects.insert(id.into(), row.clone());
            world.mc.send_row_of(id, &row, "project");
            world.sync()
        },
    );
    steps.step(
        &format!("the thread {Q} has no linked pull request"),
        |world, c, _| {
            look_at(world, &c[0])?;
            expect!(
                read_tab(world, PullRequests::count)? == 0,
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("pull request (\\d+) is linked to {Q}"),
        |world, c, _| {
            look_at(world, &c[1])?;
            let number: i64 = c[0].parse().unwrap_or(0);
            put_link(world, number)?;
            wait_for_row(world, number, true)
        },
    );

    steps.step(
        &format!("the user links pull request (\\d+) to {Q}"),
        |world, c, _| {
            look_at(world, &c[1])?;
            link(world, &c[0])
        },
    );
    steps.step(
        &format!("the user links {Q} pull request (\\d+) and {Q} pull request (\\d+) to {Q}"),
        |world, c, _| {
            look_at(world, &c[4])?;
            // The thread's own repository by number, another by its URL.
            for at in [0, 2] {
                let input = if c[at] == "acme/shop" {
                    format!("#{}", c[at + 1])
                } else {
                    format!("https://github.com/{}/pull/{}", c[at], c[at + 1])
                };
                link(world, &input)?;
                expect!(
                    read_tab(world, |t| t.problem().is_empty())?,
                    "{}",
                    describe(world)
                );
            }
            Ok(())
        },
    );
    steps.step(&format!("the user links {Q}"), |world, c, _| {
        look_at(world, "Tax work")?;
        link(world, &c[0])
    });
    steps.step("the user unlinks pull request (\\d+)", |world, c, _| {
        let key = key_of(world, c[0].parse().unwrap_or(0))?;
        update_tab(world, |tab| tab.unlink(&key))?;
        world.sync()
    });
    steps.step(
        &format!("the MC refuses to link pull requests to {Q}"),
        |world, _, _| {
            world.mc.refusals.insert(
                "thread.pull-request.link".into(),
                "Thread is archived".into(),
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user opens pull request (\\d+) from {Q}"),
        |world, c, _| {
            let key = key_of(world, c[0].parse().unwrap_or(0))?;
            update_tab(world, |tab| tab.open(&key))?;
            Ok(())
        },
    );
    steps.step(
        &format!("the user refreshes the pull requests of {Q}"),
        |world, _, _| {
            update_tab(world, PullRequests::refresh)?;
            expect!(
                read_tab(world, PullRequests::refreshing)?,
                "the tab is not refreshing"
            );
            world.sync()
        },
    );
    steps.step(
        "a review is submitted on pull request (\\d+) on GitHub",
        |world, c, _| {
            let host = &mut world.mc.part::<FakePullRequests>().host;
            if let Some(snapshot) = host.get_mut(&format!("acme/shop#{}", c[0])) {
                snapshot["reviewDecision"] = json!("approved");
            }
            Ok(())
        },
    );
    steps.step(
        &format!("the environment of {Q} becomes unreachable"),
        |world, _, _| set_online(world, false),
    );
    steps.step(
        &format!("the environment of {Q} is reachable again"),
        |world, _, _| set_online(world, true),
    );

    // Outcomes.
    steps.step(
        &format!("{Q} lists pull request (\\d+) with its current state"),
        |world, c, _| {
            let number: i64 = c[1].parse().unwrap_or(0);
            wait_for_row(world, number, true)?;
            let role = |name: &str| row_role(world, number, name);
            let open = read_tab(world, PullRequests::link_open)?;
            expect!(
                role("title") == "Tax line fix"
                    && role("stateLabel") == "Open"
                    && role("checksLabel") == "Checks passing"
                    && role("reviewLabel") == "Review required"
                    && role("sourceLabel") == "Linked by you"
                    && !open,
                "{}",
                describe(world)
            );
            let command = world.mc.commands.last().cloned().unwrap_or(Value::Null);
            expect!(
                command["type"] == "thread.pull-request.link"
                    && command["repository"] == "acme/shop"
                    && text(&command["url"])
                        == format!("https://github.com/acme/shop/pull/{}", c[1]),
                "{}",
                show(&command)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} lists pull request (\\d+) of {Q}"),
        |world, c, _| {
            let number: i64 = c[1].parse().unwrap_or(0);
            wait_for_row(world, number, true)?;
            let key = key_of(world, number)?;
            expect!(
                key.ends_with(&format!("/{}#{}", c[2], c[1]))
                    && read_tab(world, |t| t.problem().is_empty())?,
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} no longer lists pull request (\\d+)"),
        |world, c, _| wait_for_row(world, c[1].parse().unwrap_or(0), false),
    );
    steps.step(&format!("{Q} lists no pull requests"), |world, _, _| {
        expect!(
            read_tab(world, PullRequests::count)? == 0,
            "{}",
            describe(world)
        );
        let panel = world.state("panel");
        expect!(
            at(&panel, "canAdd.pullRequests") == &json!(false),
            "{}",
            show(&panel)
        );
        Ok(())
    });
    steps.step(&format!("{Q} lists both pull requests"), |world, _, _| {
        world.wait_for_with(
            |w| read_tab(w, PullRequests::count).is_ok_and(|n| n == 2),
            |w| describe(w),
        )?;
        expect!(
            key_of(world, 42)? == "github.com/acme/shop#42"
                && key_of(world, 7)? == "github.com/acme/api#7",
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        &format!("{Q} shows the new review state after the next sync"),
        |world, _, _| {
            sync_links(&mut world.mc, THREAD);
            world.sync()?;
            world.wait_for_with(
                |w| row_role(w, 42, "reviewLabel") == "Approved",
                |w| describe(w),
            )
        },
    );
    steps.step(&format!("{Q} shows the new review state"), |world, _, _| {
        world.wait_for_with(
            |w| row_role(w, 42, "reviewLabel") == "Approved",
            |w| describe(w),
        )?;
        expect!(
            !read_tab(world, PullRequests::refreshing)?,
            "the tab is still refreshing"
        );
        Ok(())
    });
    steps.step(
        "pull request (\\d+) is read from GitHub again",
        |world, c, _| {
            let invalidated = world.mc.part::<FakePullRequests>().invalidated.clone();
            let wanted = json!({"host": "github.com", "repository": "acme/shop",
                                "number": c[0].parse::<i64>().unwrap_or(0)});
            expect!(
                invalidated.len() == 1 && invalidated[0] == wanted,
                "the MC was asked to read {} pull requests",
                invalidated.len()
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user is told no project in this environment can read {Q}"),
        |world, c, _| {
            let problem = read_tab(world, |t| t.problem().to_owned())?;
            expect!(
                problem == format!("No project in this environment can read {}.", c[0]),
                "{}",
                describe(world)
            );
            for command in &world.mc.commands {
                expect!(
                    command["type"] != "thread.pull-request.link",
                    "the link was sent"
                );
            }
            Ok(())
        },
    );
    steps.step(
        "the user is told pull request (\\d+) could not be linked",
        |world, _, _| {
            let (problem, open, linking) = read_tab(world, |t| {
                (t.problem().to_owned(), t.link_open(), t.linking())
            })?;
            expect!(
                problem == "Could not link the pull request: Thread is archived"
                    && open
                    && !linking,
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} still lists pull request (\\d+)"),
        |world, c, _| {
            let online = read_tab(world, PullRequests::online)?;
            expect!(
                row_of(world, c[1].parse().unwrap_or(0)).is_some() && !online,
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the user cannot link, unlink or refresh pull requests",
        |world, _, _| {
            let sent = world.mc.commands.len();
            let key = key_of(world, 42)?;
            update_tab(world, PullRequests::refresh)?;
            update_tab(world, |tab| tab.unlink(&key))?;
            let obj = tab_object(world)?;
            ThreadPullRequests::link(world.engine(), obj, "#7");
            world.sync()?;
            let invalidated = world.mc.part::<FakePullRequests>().invalidated.is_empty();
            let busy = read_tab(world, |t| t.refreshing() || t.linking())?;
            expect!(
                world.mc.commands.len() == sent && invalidated && !busy,
                "something was sent while offline; {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the user can link, unlink and refresh pull requests",
        |world, _, _| {
            update_tab(world, PullRequests::refresh)?;
            world.sync()?;
            expect!(
                world.mc.part::<FakePullRequests>().invalidated.len() == 1,
                "the refresh was not sent"
            );
            let key = key_of(world, 42)?;
            update_tab(world, |tab| tab.unlink(&key))?;
            world.sync()?;
            wait_for_row(world, 42, false)?;
            link(world, "42")?;
            wait_for_row(world, 42, true)
        },
    );

    // The Pull request review tab.
    steps.step(
        &format!("the open pull request (\\d+)(?: by {Q})?"),
        |world, c, _| {
            let number: i64 = c[0].parse().unwrap_or(0);
            let author = c
                .get(1)
                .filter(|a| !a.is_empty())
                .map_or("octocat", String::as_str);
            let fake = world.mc.part::<FakeReview>();
            fake.author = author.into();
            fake.comments = vec![
                json!({"id": "c1", "kind": "comment", "author": actor("ada"),
                                        "body": "Why round up?",
                                        "createdAt": "2026-09-23T09:30:00Z",
                                        "reviewState": null}),
            ];
            serve_review(&mut world.mc);
            look_at(world, "Tax work")?;
            put_link(world, number)?;
            wait_for_row(world, number, true)
        },
    );
    // A thread started on a pull request the user names (PullRequestThreadController).
    steps.step(
        &format!("the user pastes {Q} to start a pull request thread"),
        |world, c, _| {
            // The MC resolves the link without checking anything out (git.resolvePullRequest),
            // and prepares the checkout when asked (git.preparePullRequestThread).
            let pull_request = json!({"number": 42, "title": "Add tax to the cart", "url": c[0],
                                      "baseBranch": "main", "headBranch": "feature/tax",
                                      "state": "open"});
            let resolved = pull_request.clone();
            world.mc.on_rpc("git.resolvePullRequest", move |mc, rpc| {
                mc.reply(rpc, json!({"pullRequest": resolved}));
                Ok(())
            });
            world.mc.on_rpc("git.preparePullRequestThread", move |mc, rpc| {
                let worktree = rpc.payload["mode"] == "worktree";
                mc.reply(
                    rpc,
                    json!({"pullRequest": pull_request, "branch": "feature/tax",
                           "worktreePath": if worktree { json!("/work/worktrees/pr-42") } else { Value::Null },
                           "isOnPullRequestHead": true}),
                );
                Ok(())
            });
            look_at(world, "Tax work")?;
            Brick::show(
                world,
                "import QtQuick\nimport HalC2.Bricks\nItem { PullRequestThreadDialog {} }\n",
                640.0,
                480.0,
            )?;
            // From the command palette's entry.
            let commands = Commands::of(world.engine());
            expect!(
                commands.contains(world.engine(), "pullRequestThread.open"),
                "no command starts a pull request thread"
            );
            commands.run(world.engine(), "pullRequestThread.open");
            let brick = shown(world)?;
            let field = brick.item(world, "pullRequestThreadReference")?;
            world.wait_for("the dialog to ask for a pull request", move |w| {
                brick.flag(w, field, "visible")
            })?;
            brick.click(world, "pullRequestThreadReference")?;
            brick.write(world, field, "text", ljos::prelude::Value::from(c[0].as_str()))?;
            brick.press(world, "enter")?;
            world.sync()
        },
    );
    steps.step(
        "the user sees the pull request's title and branches before choosing local or worktree",
        |world, _, _| {
            let brick = shown(world)?;
            world.wait_for_with(
                move |w| {
                    brick.shows(w, "#42 Add tax to the cart").unwrap_or(false)
                        && brick.shows(w, "feature/tax → main").unwrap_or(false)
                },
                |w| {
                    format!(
                        "the pull request to be shown; the dialog is {}",
                        show(&w.state("pullRequestThread"))
                    )
                },
            )?;
            let resolved = asked(world, "git.resolvePullRequest");
            expect!(
                resolved.len() == 1
                    && resolved[0]["cwd"] == "/work/shop"
                    && resolved[0]["reference"] == "https://github.com/acme/shop/pull/42",
                "the MC was asked to resolve {}",
                resolved.len()
            );
            let local = brick.item(world, "pullRequestThreadLocal")?;
            let worktree = brick.item(world, "pullRequestThreadWorktree")?;
            expect!(
                brick.flag(world, local, "visible") && brick.flag(world, worktree, "visible"),
                "local and worktree are not both offered"
            );
            // Nothing was checked out to show it.
            expect!(
                asked(world, "git.preparePullRequestThread").is_empty()
                    && asked(world, "orchestration.launchThread").is_empty(),
                "the pull request was checked out before the user chose"
            );
            // Chosen, the worktree is prepared and the window moves to the new thread in it.
            brick.click(world, "pullRequestThreadWorktree")?;
            world.wait_for("the thread to be started", |w| {
                asked(w, "orchestration.launchThread").len() == 1
            })?;
            let prepared = asked(world, "git.preparePullRequestThread")
                .first()
                .cloned()
                .unwrap_or(Value::Null);
            let launched = asked(world, "orchestration.launchThread")
                .first()
                .cloned()
                .unwrap_or(Value::Null);
            let strategy = &launched["workspaceStrategy"];
            expect!(
                prepared["mode"] == "worktree"
                    && prepared["threadId"] == launched["threadId"]
                    && launched["title"] == "#42 Add tax to the cart"
                    && strategy["type"] == "existing_worktree"
                    && strategy["worktreePath"] == "/work/worktrees/pr-42"
                    && strategy["branch"] == "feature/tax",
                "the MC was asked {} then {}",
                show(&prepared),
                show(&launched)
            );
            let key = format!(
                "{}:{}",
                world.mc.environment_id,
                text(&launched["threadId"])
            );
            world.wait_for("the new thread to open", move |w| {
                w.with::<Navigation, _>(|n, _| n.thread_key() == key)
                    .unwrap_or(false)
                    && w.state("pullRequestThread").is_null()
            })
        },
    );

    // A pull request a message mentions, linked from that message.
    steps.step(&format!("a message in {Q} mentions {Q}"), |world, c, _| {
        look_at(world, &c[0])?;
        start_run(world, 30, "running")?;
        add_item(
            world,
            "assistant_message",
            json!({"text": format!("I opened {} for the tax line.", c[1])}),
        )?;
        settle_run(world, "completed", 30)?;
        wait_for_row(world, 42, false)
    });
    steps.step(
        "the user links that pull request from the mention",
        |world, _, _| {
            Brick::show(
                world,
                "import QtQuick\nimport HalC2.Bricks\nThreadView { anchors.fill: parent }\n",
                820.0,
                700.0,
            )?;
            let brick = shown(world)?;
            world.wait_for("the message to offer linking its pull request", move |w| {
                brick
                    .find_visible(w, "linkPullRequest")
                    .ok()
                    .flatten()
                    .is_some()
            })?;
            let button = brick.find_visible(world, "linkPullRequest")?;
            let Some(button) = button else {
                fail!("the link button went away");
            };
            let (x, y) = brick.at(world, button, 0.5, 0.5)?;
            world.click_at(x, y)?;
            world.sync()
        },
    );
    steps.step(&format!("{Q} lists pull request (\\d+)"), |world, c, _| {
        let number: i64 = c[1].parse().unwrap_or(0);
        wait_for_row(world, number, true)?;
        expect!(
            row_role(world, number, "title") == "Tax line fix",
            "{}",
            describe(world)
        );
        Ok(())
    });

    // A stack of pull requests on the host (stacked-pull-requests.feature).
    steps.step(
        &format!("the stack onto {Q} of pull requests (\\d+), (\\d+) and (\\d+), bottom to top"),
        |world, c, _| {
            let fake = world.mc.part::<FakePullRequests>();
            fake.stack_base = c[0].clone();
            fake.stack = c[1..4].iter().map(|n| n.parse().unwrap_or(0)).collect();
            Ok(())
        },
    );
    steps.step(
        "the user chooses to merge the stack at pull request (\\d+)",
        |world, c, _| {
            let brick = review_stack(world, c[0].parse().unwrap_or(0))?;
            expect!(
                brick.shows(world, "Merge stack (2)")?,
                "the stack does not offer to merge two layers"
            );
            brick.click(world, "reviewStackMerge")
        },
    );
    steps.step(
        &format!("the user is asked to confirm merging (\\d+) pull requests into {Q} with the chosen method"),
        |world, c, _| {
            let confirmation = read_review(world, |r| r.stack_confirmation().clone())?;
            let title = text(&confirmation["title"]);
            let description = text(&confirmation["description"]);
            expect!(
                title == format!("Merge {} pull requests?", c[0])
                    && description.starts_with(&format!(
                        "Merge #42 and its unmerged layers below into {} using merge.",
                        c[1]
                    )),
                "the user is asked {}",
                show(&confirmation)
            );
            let brick = shown(world)?;
            let (t, d) = (title.clone(), description.clone());
            world.wait_for("the confirmation to be drawn", move |w| {
                brick.shows(w, &t).unwrap_or(false) && brick.shows(w, &d).unwrap_or(false)
            })?;
            // Nothing is merged before the answer; cancelling asks nothing of the host.
            expect!(
                actions(world).is_empty(),
                "the host was asked before the user confirmed"
            );
            brick.click(world, "reviewStackConfirmCancel")?;
            world.sync()?;
            let dropped = read_review(world, |r| r.stack_confirmation().as_object().is_none_or(|o| o.is_empty()))?;
            expect!(
                dropped && actions(world).is_empty(),
                "cancelling did not drop the merge"
            );
            // Confirmed, the two layers go with the heads that were shown.
            brick.click(world, "reviewStackMerge")?;
            brick.click(world, "reviewStackConfirmAccept")?;
            world.wait_for("the merge to be asked of the host", |w| {
                w.mc.peek::<FakeReview>().is_some_and(|f| f.actions.len() == 1)
            })?;
            let action = actions(world).first().cloned().unwrap_or(Value::Null);
            let heads = action["expectedStackHeads"].as_array().cloned().unwrap_or_default();
            expect!(
                action["action"] == "merge"
                    && action["stackNumber"] == 1
                    && action["number"] == 42
                    && action["mergeMethod"] == "merge"
                    && heads.len() == 2
                    && heads[0]["number"] == 41
                    && heads[1]["headSha"] == "sha-42",
                "the host was asked {}",
                show(&action)
            );
            Ok(())
        },
    );
    steps.step("the user chooses to rebase the stack", |world, _, _| {
        let brick = review_stack(world, 42)?;
        brick.click(world, "reviewStackRebase")
    });
    steps.step(
        "the user is warned that branch history is rewritten and checks may restart",
        |world, _, _| {
            let confirmation = read_review(world, |r| r.stack_confirmation().clone())?;
            let warning = "Rebase the remote branches from bottom to top onto main. This rewrites branch history and may restart checks. If a layer fails, earlier updates remain.";
            expect!(
                confirmation["title"] == "Rebase 3 pull requests?"
                    && confirmation["description"] == warning,
                "the user is asked {}",
                show(&confirmation)
            );
            let brick = shown(world)?;
            world.wait_for("the warning to be drawn", move |w| {
                brick.shows(w, warning).unwrap_or(false)
            })?;
            expect!(
                actions(world).is_empty(),
                "the host was asked before the user confirmed"
            );
            brick.click(world, "reviewStackConfirmAccept")?;
            world.wait_for("the rebase to be asked of the host", |w| {
                w.mc.peek::<FakeReview>().is_some_and(|f| f.actions.len() == 1)
            })?;
            let action = actions(world).first().cloned().unwrap_or(Value::Null);
            expect!(
                action["action"] == "update-branch"
                    && action["updateMethod"] == "rebase"
                    && action["number"] == 43
                    && action["expectedStackHeads"].as_array().map(Vec::len) == Some(3),
                "the host was asked {}",
                show(&action)
            );
            Ok(())
        },
    );
    steps.step("the last stack refresh failed", |world, _, _| {
        let brick = review_stack(world, 42)?;
        world.mc.part::<FakeReview>().stack_fails = true;
        brick.click(world, "reviewReload")?;
        world.sync()
    });
    steps.step("the user looks at the stack", |world, _, _| {
        world.wait_for_with(
            |w| stack_of(w)["stale"].as_bool() == Some(true),
            |w| format!("the stack; it is {}", show(&stack_of(w))),
        )
    });
    steps.step(
        "the stack is marked as possibly stale with a way to retry",
        |world, _, _| {
            let brick = shown(world)?;
            // What was read before is still shown, with the notice; nothing can be done to it meanwhile.
            let stack = stack_of(world);
            let notice = "Stack data may be stale. We couldn’t refresh it.";
            expect!(
                stack["size"] == 3
                    && stack["notice"] == notice
                    && stack["canMerge"] != true
                    && stack["canRebase"] != true,
                "the stack is {}",
                show(&stack)
            );
            world.wait_for("the notice and its retry to be drawn", move |w| {
                brick.shows(w, notice).unwrap_or(false)
                    && brick
                        .find(w, "reviewStackRetry")
                        .ok()
                        .flatten()
                        .is_some_and(|b| brick.flag(w, b, "visible"))
            })?;
            // The retry reads the stack again; once the host answers the notice goes.
            world.mc.part::<FakeReview>().stack_fails = false;
            let reads = world.mc.part::<FakeReview>().stack_reads;
            brick.click(world, "reviewStackRetry")?;
            world.wait_for("the stack to be read again", |w| {
                stack_of(w)["stale"].as_bool() != Some(true)
            })?;
            let stack = stack_of(world);
            expect!(
                world.mc.part::<FakeReview>().stack_reads == reads + 1
                    && stack["canRebase"] == true,
                "the stack is {}",
                show(&stack)
            );
            Ok(())
        },
    );
    steps.step(
        "its pull request shows it is layer (\\d+) of (\\d+)",
        |world, c, _| {
            let wanted = format!("Layer {} of {}", c[0], c[1]);
            let label = wanted.clone();
            world.wait_for_with(
                move |w| {
                    read_tab(w, |t| t.row_count() == 1 && role_text(t, 0, "stackLabel") == label)
                        .unwrap_or(false)
                },
                |w| {
                    let read = read_tab(w, |t| {
                        if t.row_count() > 0 { role_text(t, 0, "stackLabel") } else { String::new() }
                    })
                    .unwrap_or_default();
                    format!("{}; the stack reads \"{read}\"", describe(w))
                },
            )?;
            Brick::show(
                world,
                "import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\nPullRequestsPanel { source: Panel.pullRequests; anchors.fill: parent }\n",
                420.0,
                500.0,
            )?;
            let brick = shown(world)?;
            let line = format!("acme/shop #42 · feature/tax → main · {wanted}");
            world.wait_for("the tab to draw the layer", move |w| {
                brick.shows(w, &line).unwrap_or(false)
            })
        },
    );

    // The branch's own pull request, from the composer's chip.
    steps.step(
        &format!("pull request (\\d+) is the branch's pull request of {Q}"),
        |world, c, _| {
            let number: i64 = c[0].parse().unwrap_or(0);
            let url = format!("https://github.com/acme/shop/pull/{}", c[0]);
            let folder = format!("/work/{PROJECT}");
            world.mc.checkouts.insert(
                folder.clone(),
                Rc::new(move |_| {
                    json!({"local": {"isRepo": true, "refName": "feature/tax"},
                           "remote": {"hasUpstream": true,
                                      "pr": {"number": number, "title": "Tax line fix",
                                             "url": url, "state": "open"}}})
                }),
            );
            look_at(world, &c[1])?;
            // The checkout is already followed (the landing draft's): the MC says what it found.
            let status = match world.mc.checkouts.get(&folder).cloned() {
                Some(status) => status(&mut world.mc),
                None => Value::Null,
            };
            for id in world.mc.subscribers("vcs") {
                if world.mc.shape_of(id)["cwd"] != json!(folder) {
                    continue;
                }
                world.mc.send(&json!({"t": "vcs", "id": id,
                                      "event": {"_tag": "localUpdated", "local": status["local"]}}));
                world.mc.send(&json!({"t": "vcs", "id": id,
                                      "event": {"_tag": "remoteUpdated", "remote": status["remote"]}}));
            }
            world.sync()?;
            world.wait_for_with(
                move |w| at(&w.state("workspace"), "git.pullRequest.number").as_i64() == Some(number),
                |w| format!("the composer to name the pull request; the workspace is {}", show(&w.state("workspace"))),
            )
        },
    );
    steps.step(
        "the user opens the pull request from the thread",
        |world, _, _| {
            world.dispatch("workspace.openPullRequest", json!({}))?;
            world.sync()
        },
    );
    steps.step("pull request (\\d+) opens", |world, c, _| {
        let opened = world.opened_urls();
        expect!(
            opened == [format!("https://github.com/acme/shop/pull/{}", c[0])],
            "the browser opened {}",
            opened.len()
        );
        Ok(())
    });

    // Merging (pull-request-actions.feature), from the review's Overview.
    steps.step(
        &format!("the user has write access to {Q}"),
        |world, _, _| {
            world.mc.part::<FakeReview>().write_access = true;
            Ok(())
        },
    );
    steps.step(
        "the user merges pull request (\\d+) from its review with the default merge method",
        |world, c, _| {
            open_review(world, c[0].parse().unwrap_or(0))?;
            let detail = read_review(world, |r| r.detail().clone())?;
            expect!(
                detail["canMerge"] == true,
                "merging is not offered: {}",
                show(&detail)
            );
            let brick = show_review(world, 700.0, 800.0)?;
            world.wait_for("the review to offer Merge", move |w| {
                brick
                    .find(w, "reviewMerge")
                    .ok()
                    .flatten()
                    .is_some_and(|b| brick.flag(w, b, "visible"))
            })?;
            brick.click(world, "reviewMerge")?;
            world.sync()
        },
    );
    steps.step(
        "the review shows pull request (\\d+) as merged",
        |world, c, _| {
            world.wait_for_with(
                |w| {
                    read_review(w, |r| r.detail()["stateLabel"] == "Merged" && !r.busy())
                        .unwrap_or(false)
                },
                |w| {
                    format!(
                        "{}; the host was asked {} actions; the detail is {}",
                        describe_review(w),
                        w.mc.peek::<FakeReview>().map_or(0, |f| f.actions.len()),
                        show(&read_review(w, |r| r.detail().clone()).unwrap_or_default())
                    )
                },
            )?;
            let done = actions(world);
            // The default method: the first the repository allows.
            expect!(
                done.len() == 1
                    && done[0]["action"] == "merge"
                    && done[0]["mergeMethod"] == "merge"
                    && done[0]["number"].as_i64() == c[0].parse::<i64>().ok(),
                "the host was asked {}",
                done.first().map_or("nothing".to_owned(), show)
            );
            // A merged pull request offers no merge.
            let can_merge = read_review(world, |r| r.detail()["canMerge"] == true)?;
            expect!(!can_merge, "{}", describe_review(world));
            let brick = shown(world)?;
            world.wait_for("Merge to go away", move |w| {
                brick
                    .find(w, "reviewMerge")
                    .ok()
                    .flatten()
                    .is_none_or(|b| !brick.flag(w, b, "visible"))
            })
        },
    );
    steps.step(
        &format!("{Q} is marked viewed in pull request (\\d+)"),
        |world, c, _| {
            world.mc.part::<FakeReview>().viewed.insert(c[0].clone());
            Ok(())
        },
    );
    steps.step(
        "GitHub refuses viewed marks on pull request (\\d+)",
        |world, _, _| {
            world.mc.part::<FakeReview>().refuse_viewed = true;
            Ok(())
        },
    );
    steps.step(
        "an unresolved review thread on pull request (\\d+)",
        |world, _, _| {
            world.mc.part::<FakeReview>().threads = vec![json!({
                "id": "th1", "path": "src/cart.ts", "line": 2,
                "isResolved": false, "isOutdated": false,
                "comments": [{"author": actor("ada"), "body": "Round down here."}]})];
            Ok(())
        },
    );
    steps.step("the user opens pull request (\\d+)", |world, c, _| {
        open_review(world, c[0].parse().unwrap_or(0))
    });
    steps.step("the user opened pull request (\\d+)", |world, c, _| {
        open_review(world, c[0].parse().unwrap_or(0))
    });
    steps.step(
        &format!("the user marks {Q} (viewed|not viewed) on the review page"),
        |world, c, _| {
            update_review(world, |r| r.set_viewed(&c[0], c[1] == "viewed"))?;
            world.sync()
        },
    );
    steps.step(
        &format!("the user comments {Q} on the review page"),
        |world, c, _| {
            let sent = update_review(world, |r| r.comment(&c[0]))?;
            expect!(sent, "{}", describe_review(world));
            world.sync()
        },
    );
    steps.step(
        "the user comments with only spaces on the review page",
        |world, _, _| {
            let sent = update_review(world, |r| r.comment("   "))?;
            expect!(!sent, "{}", describe_review(world));
            Ok(())
        },
    );
    steps.step(
        "the user approves pull request (\\d+) on the review page",
        |world, _, _| {
            let sent = update_review(world, |r| r.submit_review("approve", ""))?;
            expect!(sent, "{}", describe_review(world));
            world.sync()
        },
    );
    steps.step(
        "the user requests changes on the review page with no summary",
        |world, _, _| {
            let sent = update_review(world, |r| r.submit_review("request-changes", " "))?;
            expect!(!sent, "{}", describe_review(world));
            Ok(())
        },
    );
    steps.step(
        "the user (resolves|unresolves) the thread on the review page",
        |world, c, _| {
            let id = text(&review_thread(world)?["id"]);
            update_review(world, |r| r.set_thread_resolved(&id, c[0] == "resolves"))?;
            world.sync()
        },
    );
    steps.step("the user copies the pull request number", |world, _, _| {
        let ran = Commands::of(world.engine()).run(world.engine(), "pullRequest.copyNumber");
        expect!(ran, "{}", show(&world.state("panel")));
        Ok(())
    });

    // Outcomes.
    steps.step(
        "the description, conversation, checks and code are shown on its review page",
        |world, _, _| {
            world.wait_for_with(
                |w| read_review(w, |r| r.conversation().len() == 1).unwrap_or(false),
                |w| describe_review(w),
            )?;
            let detail = read_review(world, |r| r.detail().clone())?;
            let checks = detail["checks"].as_array().cloned().unwrap_or_default();
            expect!(
                detail["title"] == "Tax line fix"
                    && detail["body"] == "Rounds the tax line."
                    && detail["author"] == "octocat"
                    && detail["branches"] == "feature/tax → main"
                    && detail["stateLabel"] == "Open"
                    && detail["behindBy"] == 2
                    && checks.len() == 1
                    && checks[0]["status"] == "success",
                "{}",
                show(&detail)
            );
            let paths = code(world, |d| d.paths())?;
            expect!(
                paths == ["src/cart.ts", "src/tax.ts"] && world.mc.part::<FakeReview>().slices == 2,
                "{}",
                describe_review(world)
            );
            let panel = world.state("panel");
            let last = at(&panel, "tabs")
                .as_array()
                .and_then(|tabs| tabs.last())
                .map(|tab| text(&tab["title"]))
                .unwrap_or_default();
            expect!(last == "PR #42", "{}", show(&panel));
            Ok(())
        },
    );
    steps.step(
        "a viewed file collapses and the viewed count goes up",
        |world, _, _| {
            expect!(
                expanded(world, "src/cart.ts") && viewed_count(world) == 0,
                "{}",
                describe_review(world)
            );
            update_review(world, |r| r.set_viewed("src/cart.ts", true))?;
            expect!(
                !expanded(world, "src/cart.ts") && viewed_count(world) == 1,
                "{}",
                describe_review(world)
            );
            world.sync()?;
            world.wait_for_with(
                |w| {
                    w.mc.peek::<FakeReview>()
                        .is_some_and(|f| f.viewed.contains("src/cart.ts"))
                },
                |w| describe_review(w),
            )
        },
    );
    steps.step(
        &format!("{Q} expands and the viewed count goes down"),
        |world, c, _| {
            expect!(
                expanded(world, &c[0]) && viewed_count(world) == 0,
                "{}",
                describe_review(world)
            );
            let path = c[0].clone();
            world.wait_for_with(
                move |w| {
                    w.mc.peek::<FakeReview>()
                        .is_some_and(|f| !f.viewed.contains(&path))
                },
                |w| describe_review(w),
            )
        },
    );
    steps.step(
        &format!("{Q} is not marked viewed on the review page"),
        |world, c, _| {
            let path = c[0].clone();
            world.wait_for_with(
                move |w| {
                    !read_review(w, |r| r.is_viewed(&path)).unwrap_or(true)
                        && expanded(w, &path)
                        && viewed_count(w) == 0
                },
                |w| describe_review(w),
            )?;
            let sent = world.mc.part::<FakeReview>().sent.clone();
            expect!(
                sent == ["pullRequests.setFilesViewed"],
                "{}",
                describe_review(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} appears in the review page's conversation"),
        |world, c, _| {
            let body = c[0].clone();
            world.wait_for_with(
                move |w| {
                    read_review(w, |r| {
                        r.conversation().last().is_some_and(|m| m["body"] == body)
                    })
                    .unwrap_or(false)
                },
                |w| describe_review(w),
            )?;
            let settled = read_review(world, |r| !r.busy() && r.problem().is_empty())?;
            expect!(settled, "{}", describe_review(world));
            Ok(())
        },
    );
    steps.step(&format!("the review page says {Q}"), |world, c, _| {
        let problem = read_review(world, |r| r.problem().to_owned())?;
        expect!(problem == c[0], "{}", describe_review(world));
        Ok(())
    });
    steps.step("nothing was sent to pull request (\\d+)", |world, _, _| {
        world.sync()?;
        let sent = world.mc.part::<FakeReview>().sent.clone();
        expect!(sent.is_empty(), "{}", sent.join(", "));
        Ok(())
    });
    steps.step(
        "the review page shows the thread (resolved|open)",
        |world, c, _| {
            let resolved = c[0] == "resolved";
            world.wait_for_with(
                move |w| review_thread(w).is_ok_and(|t| (t["resolved"] == true) == resolved),
                |w| describe_review(w),
            )
        },
    );
    steps.step(
        "the review page still shows pull request (\\d+) and sends nothing",
        |world, _, _| {
            world.wait_for_with(
                |w| read_review(w, |r| !r.online()).unwrap_or(false),
                |w| describe_review(w),
            )?;
            let title = read_review(world, |r| text(&r.detail()["title"]))?;
            let files = code(world, |d| d.file_count())?;
            expect!(
                title == "Tax line fix" && files == 2,
                "{}",
                describe_review(world)
            );
            let sent = update_review(world, |r| r.comment("Looks good"))?;
            let problem = read_review(world, |r| r.problem().to_owned())?;
            expect!(
                !sent && problem == "The environment is offline.",
                "{}",
                describe_review(world)
            );
            update_review(world, |r| r.set_viewed("src/cart.ts", true))?;
            world.sync()?;
            expect!(
                world.mc.part::<FakeReview>().sent.is_empty() && viewed_count(world) == 0,
                "{}",
                describe_review(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the user can comment on the review page again",
        |world, _, _| {
            world.wait_for_with(
                |w| read_review(w, Review::online).unwrap_or(false),
                |w| describe_review(w),
            )?;
            let sent = update_review(world, |r| r.comment("Back again"))?;
            expect!(sent, "{}", describe_review(world));
            world.sync()?;
            world.wait_for_with(
                |w| {
                    read_review(w, |r| {
                        r.conversation()
                            .last()
                            .is_some_and(|m| m["body"] == "Back again")
                    })
                    .unwrap_or(false)
                },
                |w| describe_review(w),
            )
        },
    );
}
