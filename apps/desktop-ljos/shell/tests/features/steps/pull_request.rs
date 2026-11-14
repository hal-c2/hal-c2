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
use hal_c2_shell::controllers::palette::Palette;
use hal_c2_shell::controllers::panel::RightPanel;
use hal_c2_shell::thread_view::diff::DiffModel;
use hal_c2_shell::thread_view::pull_request_links::{LinksView, ThreadLinks};
use hal_c2_shell::thread_view::pull_request_review::{PullRequestReview, Review};
use hal_c2_shell::thread_view::pull_requests::{PullRequests, ThreadPullRequests};
use hal_c2_shell::thread_view::rows::RowSource;
use hal_c2_shell::thread_view::time::Clock;
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
    /// The pull request whose row's menu is open.
    pub actions_of: i64,
    /// The numbers the MC cannot read a preview of (an issue among them).
    pub unreadable: BTreeSet<i64>,
    /// The link the scenario's message mentions.
    pub mentioned: String,
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
            actions_of: 0,
            unreadable: BTreeSet::new(),
            mentioned: String::new(),
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
    // The threads that link a pull request (pull_requests.ex linked_threads).
    mc.on_rpc("pullRequests.linkedThreads", |mc, rpc| {
        if mc.part::<FakePullRequests>().thread.is_empty() {
            return mc.pass_on(rpc);
        }
        let wanted = host_key(&rpc.payload);
        let mut threads: Vec<Value> = mc
            .threads
            .values()
            .filter(|row| {
                row["pullRequests"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .any(|link| {
                        host_key(link) == wanted
                            && link["host"] == rpc.payload["host"]
                            && text(&link["source"]) != "stack-dismissed"
                    })
            })
            .cloned()
            .collect();
        threads.sort_by_key(|row| std::cmp::Reverse(text(&row["updatedAt"])));
        let threads: Vec<Value> = threads
            .iter()
            .map(|row| {
                json!({"id": row["id"], "projectId": row["projectId"], "title": row["title"],
                       "archivedAt": row.get("archivedAt").cloned().unwrap_or(Value::Null)})
            })
            .collect();
        mc.reply(rpc, json!({"threads": threads}));
        Ok(())
    });
    // A pull request link's card (pull_requests.ex preview): GitHub's only.
    mc.on_rpc("pullRequests.preview", |mc, rpc| {
        let number = rpc.payload["number"].as_i64().unwrap_or(0);
        let fake = mc.part::<FakePullRequests>();
        let known = rpc.payload["host"] == "github.com"
            && fake.host.contains_key(&host_key(&rpc.payload))
            && !fake.unreadable.contains(&number);
        if !known {
            mc.refuse(rpc, "Pull request not found.");
            return Ok(());
        }
        let repository = text(&rpc.payload["repository"]);
        let snapshot = fake.host[&host_key(&rpc.payload)].clone();
        mc.reply(
            rpc,
            json!({"number": number, "title": snapshot["title"],
                   "url": format!("https://github.com/{repository}/pull/{number}"),
                   "isDraft": snapshot["isDraft"], "state": snapshot["state"],
                   "createdAt": "2026-09-23T06:00:00Z",
                   "author": {"login": "ada", "name": "Ada Lovelace"},
                   "projectId": rpc.payload["projectId"], "repository": repository}),
        );
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
    world.wait_for_with(move |w| row_of(w, number).is_some() == listed, describe)
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
    tell_link_problem(world);
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
    // "Linked by you · 1h ago" is read on the scenario's clock, not the wall's.
    let now = world.now();
    update_tab(world, |tab| tab.set_clock(Clock::fixed(now)))?;
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
        describe,
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
        describe_review,
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
    link_of("acme/shop", number, source, LINKED_AT)
}

/// Puts `link` on the thread's row, as the MC's sync reads it from the host.
fn put_link(world: &mut World, number: i64) -> Outcome {
    let mut row = world.mc.threads.get(THREAD).cloned().unwrap_or(Value::Null);
    row["pullRequests"] = json!([link_row(number, "manual")]);
    world.mc.threads.insert(THREAD.into(), row);
    sync_links(&mut world.mc, THREAD);
    world.sync()
}

const LINKED_AT: &str = "2026-09-23T09:05:00Z";

/// A link of `repository`'s pull request `number` as the thread's row holds it.
fn link_of(repository: &str, number: i64, source: &str, linked_at: &str) -> Value {
    json!({"host": "github.com", "repository": repository, "number": number,
           "url": format!("https://github.com/{repository}/pull/{number}"),
           "source": source, "linkedAt": linked_at,
           "snapshot": null, "stack": null})
}

/// The thread links `links` and nothing else, as the MC's sync sends them.
fn set_links(world: &mut World, links: Vec<Value>) -> Outcome {
    let mut row = world.mc.threads.get(THREAD).cloned().unwrap_or(Value::Null);
    row["pullRequests"] = Value::Array(links);
    world.mc.threads.insert(THREAD.into(), row);
    sync_links(&mut world.mc, THREAD);
    world.sync()
}

/// Opens the menu of pull request `number`'s row.
fn open_actions(world: &mut World, number: i64) -> Outcome {
    let brick = open_panel(world)?;
    let name = format!("pullRequestRow-{number}");
    world.wait_for_with(
        {
            let name = name.clone();
            move |w| brick.find(w, &name).ok().flatten().is_some()
        },
        describe,
    )?;
    let row = brick.item(world, &name)?;
    let Some(button) = brick.visible_in(world, row, "pullRequestMenu")? else {
        fail!("the row of #{number} has no menu button");
    };
    let (x, y) = brick.at(world, button, 0.5, 0.5)?;
    world.click_at(x, y)?;
    world.sync()
}

/// The visible menu entry `name` (each row has its own menu).
fn menu_item(world: &mut World, name: &str) -> Outcome<(Brick, ObjectId)> {
    let brick = open_panel(world)?;
    let wanted = name.to_owned();
    world.wait_for_with(
        move |w| brick.find_visible(w, &wanted).ok().flatten().is_some(),
        |_| "the menu entry to be shown".to_owned(),
    )?;
    match brick.find_visible(world, name)? {
        Some(item) => Ok((brick, item)),
        None => fail!("no {name} is shown"),
    }
}

/// What the tab's link field says of what was typed, for "the user is told".
/// What the tab says in place: why a reference does not link, and what each stack is.
fn tell_link_problem(world: &mut World) {
    world.told_in_place = Some(Rc::new(|w: &World| {
        read_tab(w, |tab| {
            let stacks = (0..tab.row_count())
                .filter(|&row| matches!(tab.data(row, "stackSize"), ljos::prelude::Value::Int(n) if n > 1))
                .map(|row| role_text(tab, row, "stackNote"));
            std::iter::once(tab.problem()).chain(stacks).collect()
        })
        .unwrap_or_default()
    }));
}

/// The `thread.pull-request.*` commands the MC was sent.
fn link_commands(world: &World) -> usize {
    world
        .mc
        .commands
        .iter()
        .filter(|command| text(&command["type"]).starts_with("thread.pull-request."))
        .count()
}

/// The tab drawn as PullRequestsPanel, once.
fn open_panel(world: &mut World) -> Outcome<Brick> {
    if let Ok(brick) = shown(world) {
        return Ok(brick);
    }
    Brick::show(
        world,
        "import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\nPullRequestsPanel { width: 420; height: 600; source: Panel.pullRequests }\n",
        420.0,
        600.0,
    )?;
    world.sync()?;
    shown(world)
}

/// What the host and the MC do with the pull requests the dialog names:
/// numbers the host does not know, with what it says of them, and a
/// checkout held or refused.
#[derive(Default)]
struct FakePullRequestThread {
    missing: HashMap<String, String>,
    hold_prepare: bool,
    prepare_refusal: Option<String>,
}

/// The number at the end of what was named: "7", ".../pull/7", ".../pullrequest/7".
fn resolved_pull_request(reference: &str) -> Value {
    let trimmed = reference.trim_end_matches('/');
    let digits = trimmed.len() - trimmed.trim_end_matches(|c: char| c.is_ascii_digit()).len();
    let number: i64 = trimmed[trimmed.len() - digits..].parse().unwrap_or(0);
    let url = if reference.starts_with("http") {
        reference.to_owned()
    } else {
        format!("https://github.com/acme/shop/pull/{number}")
    };
    json!({"number": number, "title": "Add tax to the cart", "url": url,
           "baseBranch": "main", "headBranch": "feature/tax", "state": "open"})
}

/// Whether both of the dialog's choices can be pressed.
fn choosable(world: &mut World) -> Outcome<bool> {
    let brick = shown(world)?;
    Ok(choosable_in(brick, world))
}

fn choosable_in(brick: Brick, world: &World) -> bool {
    ["pullRequestThreadLocal", "pullRequestThreadWorktree"]
        .iter()
        .all(|name| {
            brick
                .item(world, name)
                .is_ok_and(|item| brick.flag(world, item, "enabled"))
        })
}

/// A wait's failure, with what the dialog is.
fn dialog_is(what: &str) -> impl Fn(&World) -> String + 'static {
    let what = what.to_owned();
    move |w| {
        format!(
            "{what}; the dialog is {}",
            show(&w.state("pullRequestThread"))
        )
    }
}

/// The dialog, opened from the command palette's entry on "Tax work"'s
/// project; its field. The MC resolves what is named without checking
/// anything out (git.resolvePullRequest), and prepares the checkout when
/// asked (git.preparePullRequestThread).
fn open_pull_request_thread(world: &mut World) -> Outcome<(Brick, ObjectId)> {
    world.mc.on_rpc("git.resolvePullRequest", |mc, rpc| {
        let reference = text(&rpc.payload["reference"]);
        match mc
            .part::<FakePullRequestThread>()
            .missing
            .get(&reference)
            .cloned()
        {
            Some(reason) => mc.refuse(rpc, &reason),
            None => mc.reply(
                rpc,
                json!({"pullRequest": resolved_pull_request(&reference)}),
            ),
        }
        Ok(())
    });
    world.mc.on_rpc("git.preparePullRequestThread", |mc, rpc| {
        let fake = mc.part::<FakePullRequestThread>();
        if fake.hold_prepare {
            return Ok(());
        }
        if let Some(reason) = fake.prepare_refusal.clone() {
            mc.refuse(rpc, &reason);
            return Ok(());
        }
        let worktree = rpc.payload["mode"] == "worktree";
        let reference = text(&rpc.payload["reference"]);
        mc.reply(
            rpc,
            json!({"pullRequest": resolved_pull_request(&reference), "branch": "feature/tax",
                   "worktreePath": if worktree { json!("/work/worktrees/pr-42") } else { Value::Null },
                   "isOnPullRequestHead": true}),
        );
        Ok(())
    });
    look_at(world, "Tax work")?;
    // What the dialog says of what was typed.
    world.told_in_place = Some(Rc::new(|w: &World| {
        vec![text(&w.state("pullRequestThread")["error"])]
    }));
    Brick::show(
        world,
        "import QtQuick\nimport HalC2.Bricks\nItem { PullRequestThreadDialog {} }\n",
        640.0,
        480.0,
    )?;
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
    Ok((brick, field))
}

fn start_in_worktree(world: &mut World, number: &str) -> Outcome {
    let (brick, field) = open_pull_request_thread(world)?;
    brick.write(world, field, "text", ljos::prelude::Value::from(number))?;
    world.wait_for_with(
        move |w| choosable_in(brick, w),
        dialog_is("the pull request to resolve"),
    )?;
    brick.click(world, "pullRequestThreadWorktree")?;
    world.sync()
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);
    register_links(steps);

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
            describe,
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
            world.wait_for_with(|w| row_role(w, 42, "reviewLabel") == "Approved", describe)
        },
    );
    steps.step(&format!("{Q} shows the new review state"), |world, _, _| {
        world.wait_for_with(|w| row_role(w, 42, "reviewLabel") == "Approved", describe)?;
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
    // The link field.
    steps.step(
        &format!("the user is linking a pull request to {Q}"),
        |world, c, _| {
            look_at(world, &c[0])?;
            tell_link_problem(world);
            world.with::<RightPanel, _>(|p, engine| p.link_pull_request(engine))?;
            world.sync()?;
            expect!(
                read_tab(world, PullRequests::link_open)?,
                "the link field is closed"
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user types {Q} as the pull request to link"),
        |world, c, _| {
            update_tab(world, |tab| tab.set_reference(&c[0]))?;
            world.sync()
        },
    );
    steps.step("the user clears the pull request to link", |world, _, _| {
        update_tab(world, |tab| tab.set_reference(""))?;
        world.sync()
    });
    steps.step(&format!("{Q} is not in a project"), |world, c, _| {
        look_at(world, &c[0])?;
        let mut row = world.mc.threads.get(THREAD).cloned().unwrap_or(Value::Null);
        row["projectId"] = Value::Null;
        world.mc.threads.insert(THREAD.into(), row.clone());
        world.mc.send_row(THREAD, &row);
        world.sync()
    });
    steps.step(
        &format!("the project of {Q} is on a host whose pull request addresses are not known"),
        |world, c, _| {
            let mut project = world.mc.projects.get(PROJECT).cloned().unwrap_or(json!({}));
            project["repositoryIdentity"] = json!({"canonicalKey": "git.example.com/acme/shop",
                                                   "displayName": "acme/shop"});
            world.mc.projects.insert(PROJECT.into(), project.clone());
            world.mc.send_row_of(PROJECT, &project, "project");
            world.sync()?;
            look_at(world, &c[0])
        },
    );
    steps.step(&format!("the user links {Q} to {Q}"), |world, c, _| {
        look_at(world, &c[1])?;
        tell_link_problem(world);
        link(world, &c[0])
    });
    steps.step("the pull request cannot be linked", |world, _, _| {
        // Or the planner's link field (PlannerSteps.cpp).
        if world.mc.part::<FakePullRequests>().thread.is_empty() {
            return crate::steps::planner::cannot_be_linked(world);
        }
        expect!(
            !read_tab(world, PullRequests::can_link)? && link_commands(world) == 0,
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        &format!("the MC takes a while to link pull requests to {Q}"),
        |world, c, _| {
            look_at(world, &c[0])?;
            world.mc.hold("answers");
            Ok(())
        },
    );
    steps.step(
        "the link dialog shows \"Linking...\" and cannot be submitted again",
        |world, _, _| {
            let brick = open_panel(world)?;
            expect!(
                read_tab(world, |t| t.linking() && !t.can_link())?,
                "{}",
                describe(world)
            );
            world.wait_for_with(
                move |w| brick.shows(w, "Linking...").unwrap_or(false),
                describe,
            )?;
            let submit = brick.item(world, "pullRequestsLinkSubmit")?;
            expect!(
                !brick.flag(world, submit, "enabled"),
                "Linking... can be pressed"
            );
            let sent = link_commands(world);
            let obj = tab_object(world)?;
            ThreadPullRequests::link(world.engine(), obj, "42");
            world.sync()?;
            expect!(link_commands(world) == sent, "a second link was sent");
            Ok(())
        },
    );
    steps.step(
        &format!("the user links pull request (\\d+) to {Q} again"),
        |world, c, _| {
            world.mc.answer_held();
            world.sync()?;
            world.wait_for_with(
                |w| read_tab(w, PullRequests::linking).is_ok_and(|l| !l),
                describe,
            )?;
            link(world, &c[0])
        },
    );
    steps.step(
        "the link dialog says the pull request could not be linked and stays open",
        |world, _, _| {
            world.wait_for_with(
                |w| read_tab(w, PullRequests::linking).is_ok_and(|l| !l),
                describe,
            )?;
            let (problem, open) = read_tab(world, |t| (t.problem(), t.link_open()))?;
            expect!(
                problem.starts_with("Could not link the pull request") && open,
                "{}",
                describe(world)
            );
            let brick = open_panel(world)?;
            world.wait_for_with(move |w| brick.shows(w, &problem).unwrap_or(false), describe)
        },
    );

    // How each link came to be, and what its row offers.
    steps.step(
        &format!("pull request (\\d+) was (linked by the user|created from the thread|linked by the agent|found in the stack of another layer|dismissed from the stack) to {Q}"),
        |world, c, _| {
            let source = match c[1].as_str() {
                "linked by the user" => "manual",
                "created from the thread" => "created",
                "linked by the agent" => "agent",
                "found in the stack of another layer" => "stack",
                _ => "stack-dismissed",
            };
            look_at(world, &c[2])?;
            let number = c[0].parse().unwrap_or(0);
            set_links(world, vec![link_of("acme/shop", number, source, LINKED_AT)])
        },
    );
    steps.step(
        &format!("the user opens the pull requests of {Q}"),
        |world, c, _| {
            look_at(world, &c[0])?;
            open_panel(world).map(drop)
        },
    );
    steps.step(&format!("pull request (\\d+) says {Q}"), |world, c, _| {
        let number: i64 = c[0].parse().unwrap_or(0);
        let label = c[1].clone();
        let brick = open_panel(world)?;
        // A dismissed one is listed below the rest, its label after its title.
        let says = move |w: &World| -> (String, String) {
            if row_of(w, number).is_some() {
                return (row_role(w, number, "sourceLabel"), String::new());
            }
            read_tab(w, |t| {
                t.dismissed()
                    .into_iter()
                    .find(|entry| entry["number"].as_i64() == Some(number))
                    .map(|entry| {
                        let title = if text(&entry["title"]).is_empty() {
                            text(&entry["repository"])
                        } else {
                            text(&entry["title"])
                        };
                        let label = text(&entry["sourceLabel"]);
                        let line = format!("#{number} · {title} · {label}");
                        (label, line)
                    })
                    .unwrap_or_default()
            })
            .unwrap_or_default()
        };
        let wanted = label.clone();
        world.wait_for_with(
            move |w| {
                let (said, line) = says(w);
                said == wanted
                    && (brick.shows(w, &wanted).unwrap_or(false)
                        || (!line.is_empty() && brick.shows(w, &line).unwrap_or(false)))
            },
            move |w| format!("{}, it says {}", describe(w), says(w).0),
        )
    });
    steps.step(
        &format!("pull request (\\d+) is a layer found in the stack of {Q}"),
        |world, c, _| {
            look_at(world, &c[1])?;
            let number = c[0].parse().unwrap_or(0);
            set_links(
                world,
                vec![
                    link_of("acme/shop", 42, "manual", LINKED_AT),
                    link_of("acme/shop", number, "stack", LINKED_AT),
                ],
            )
        },
    );
    steps.step(
        &format!("the user opens the actions of pull request (\\d+) in {Q}"),
        |world, c, _| {
            look_at(world, &c[1])?;
            let number = c[0].parse().unwrap_or(0);
            wait_for_row(world, number, true)?;
            open_actions(world, number)?;
            world.mc.part::<FakePullRequests>().actions_of = number;
            Ok(())
        },
    );
    steps.step(&format!("the action is {Q}"), |world, c, _| {
        let number = world.mc.part::<FakePullRequests>().actions_of;
        expect!(
            row_role(world, number, "unlinkLabel") == c[0],
            "{}",
            describe(world)
        );
        let (brick, unlink) = menu_item(world, "pullRequestUnlink")?;
        let said = brick.text_of(world, unlink, "text");
        expect!(said == c[0], "the menu offers {said}, not {}", c[0]);
        Ok(())
    });
    steps.step(
        &format!("a pull request the user linked is offered {Q} instead"),
        |world, c, _| {
            expect!(
                row_role(world, 42, "source") == "manual"
                    && row_role(world, 42, "unlinkLabel") == c[0],
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "pull request (\\d+) is a layer of a GitHub stack of 3",
        |world, c, _| {
            look_at(world, "Tax work")?;
            let first: i64 = c[0].parse().unwrap_or(0);
            let fake = world.mc.part::<FakePullRequests>();
            fake.stack_base = "main".into();
            fake.stack = vec![first, first + 1, first + 2];
            let links = fake
                .stack
                .clone()
                .into_iter()
                .map(|number| {
                    let source = if number == first { "manual" } else { "stack" };
                    link_of("acme/shop", number, source, LINKED_AT)
                })
                .collect();
            set_links(world, links)
        },
    );
    steps.step(
        "pull requests (\\d+), (\\d+) and (\\d+) are chained by their base branches on a host with no stacks of its own",
        |world, c, _| {
            look_at(world, "Tax work")?;
            let fake = world.mc.part::<FakePullRequests>();
            let mut links = Vec::new();
            let mut base = "main".to_owned();
            for (at, number) in c.iter().take(3).enumerate() {
                let mut snapshot = fake.host.get("acme/shop#42").cloned().unwrap_or(json!({}));
                let head = format!("tax/{at}");
                snapshot["headBranch"] = json!(head);
                snapshot["baseBranch"] = json!(base);
                base = head;
                fake.host.insert(format!("acme/shop#{number}"), snapshot);
                links.push(link_of("acme/shop", number.parse().unwrap_or(0), "manual", LINKED_AT));
            }
            set_links(world, links)
        },
    );
    steps.step(
        &format!("pull request (\\d+) was just linked to {Q} and the host has not answered"),
        |world, c, _| {
            look_at(world, &c[1])?;
            world
                .mc
                .part::<FakePullRequests>()
                .host
                .remove(&format!("acme/shop#{}", c[0]));
            let number = c[0].parse().unwrap_or(0);
            set_links(
                world,
                vec![link_of("acme/shop", number, "manual", LINKED_AT)],
            )
        },
    );
    steps.step(
        &format!("pull request (\\d+) is listed with its repository and {Q}"),
        |world, c, _| {
            let brick = open_panel(world)?;
            let row = format!("pullRequestRow-{}", c[0]);
            let wanted = c[1].clone();
            world.wait_for_with(
                move |w| {
                    let named = brick
                        .find(w, &row)
                        .ok()
                        .flatten()
                        .and_then(|item| {
                            brick
                                .visible_in(w, item, "pullRequestRepository")
                                .ok()
                                .flatten()
                        })
                        .is_some_and(|item| brick.text_of(w, item, "text").contains("acme/shop"));
                    named && brick.shows(w, &wanted).unwrap_or(false)
                },
                describe,
            )
        },
    );
    // Two repositories' pull requests of one number.
    steps.step(
        &format!("{Q} links pull request (\\d+) of {Q} and pull request (\\d+) of {Q}"),
        |world, c, _| {
            look_at(world, &c[0])?;
            let (first, second) = (c[1].parse().unwrap_or(0), c[3].parse().unwrap_or(0));
            set_links(
                world,
                vec![
                    link_of(&c[2], first, "manual", LINKED_AT),
                    link_of(&c[4], second, "manual", LINKED_AT),
                ],
            )?;
            world.wait_for_with(
                |w| read_tab(w, |tab| tab.row_count() == 2).unwrap_or(false),
                describe,
            )
        },
    );
    steps.step(
        "the user looks at the thread's linked pull requests",
        |world, _, _| open_panel(world).map(|_| ()),
    );
    steps.step(
        "each row names its pull request's repository",
        |world, _, _| {
            let brick = open_panel(world)?;
            // Each model row's (number, repository), and the rows that show it:
            // a row whose `repository` is its own and whose repository line names it.
            let named = move |w: &World| -> Vec<String> {
                let wanted: Vec<(String, String)> = read_tab(w, |tab| {
                    (0..tab.row_count())
                        .map(|row| {
                            (
                                role_text(tab, row, "number"),
                                role_text(tab, row, "repository"),
                            )
                        })
                        .collect()
                })
                .unwrap_or_default();
                let mut named = Vec::new();
                for (number, repository) in &wanted {
                    let row = format!("pullRequestRow-{number}");
                    for n in 0..wanted.len() {
                        let Some(item) = brick.find_visible_nth(w, &row, n).ok().flatten() else {
                            break;
                        };
                        if brick.text_of(w, item, "repository") != *repository {
                            continue;
                        }
                        let text = brick
                            .visible_in(w, item, "pullRequestRepository")
                            .ok()
                            .flatten()
                            .map(|line| brick.text_of(w, line, "text"))
                            .unwrap_or_default();
                        if text.contains(repository.as_str()) {
                            named.push(text);
                        }
                    }
                }
                named
            };
            world.wait_for_with(
                move |w| named(w).len() == 2,
                move |w| format!("{}, the rows say {}", describe(w), named(w).join("; ")),
            )
        },
    );
    steps.step(
        &format!("pull request (\\d+) was linked to {Q} by the user an hour ago"),
        |world, c, _| {
            look_at(world, &c[1])?;
            let at = (world.now() - chrono::Duration::hours(1))
                .to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
            let number = c[0].parse().unwrap_or(0);
            set_links(world, vec![link_of("acme/shop", number, "manual", &at)])
        },
    );
    steps.step(
        "the user rests the pointer on the number of pull request (\\d+)",
        |world, c, _| {
            let brick = open_panel(world)?;
            let row = format!("pullRequestRow-{}", c[0]);
            world.wait_for_with(
                {
                    let row = row.clone();
                    move |w| brick.find(w, &row).ok().flatten().is_some()
                },
                describe,
            )?;
            let row = brick.item(world, &row)?;
            let Some(number) = brick.visible_in(world, row, "pullRequestNumber")? else {
                fail!("the row has no number");
            };
            let (x, y) = brick.at(world, number, 0.5, 0.5)?;
            world.hover_at(x, y)?;
            world.sync()
        },
    );
    steps.step(
        &format!("the user is told {Q} and how long ago"),
        |world, c, _| {
            let brick = open_panel(world)?;
            let note = format!("{} · 1h ago", c[0]);
            world.wait_for_with(
                {
                    let note = note.clone();
                    move |w| {
                        read_tab(w, |t| role_text(t, 0, "linkedNote")).is_ok_and(|n| n == note)
                            && brick.shows(w, &note).unwrap_or(false)
                    }
                },
                move |w| {
                    format!(
                        "{}, the note is {}",
                        describe(w),
                        read_tab(w, |t| role_text(t, 0, "linkedNote")).unwrap_or_default()
                    )
                },
            )
        },
    );
    steps.step("the user can copy its link", |world, _, _| {
        let (brick, copy) = menu_item(world, "pullRequestCopyLink")?;
        let (x, y) = brick.at(world, copy, 0.5, 0.5)?;
        world.click_at(x, y)?;
        world.sync()?;
        let copied = world.clipboard();
        expect!(
            copied == "https://github.com/acme/shop/pull/42",
            "the clipboard holds \"{copied}\""
        );
        Ok(())
    });
    steps.step("the user can open it", |world, _, _| {
        open_actions(world, 42)?;
        let (brick, open) = menu_item(world, "pullRequestOpen")?;
        let (x, y) = brick.at(world, open, 0.5, 0.5)?;
        world.click_at(x, y)?;
        world.sync()?;
        let opened = world.opened_urls();
        expect!(
            opened
                .iter()
                .any(|url| url == "https://github.com/acme/shop/pull/42"),
            "the browser opened {}",
            show(&json!(opened))
        );
        Ok(())
    });

    // What the tab says with nothing to list.
    steps.step(
        "the environment does not support several linked pull requests per thread",
        |world, _, _| {
            world.mc.capabilities["threadPullRequests"] = json!(false);
            world.mc.send_snapshot();
            world.sync()
        },
    );
    steps.step(&format!("{Q} has no linked pull request"), |world, c, _| {
        look_at(world, &c[0])?;
        expect!(
            read_tab(world, PullRequests::count)? == 0,
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step("the user can link one", |world, _, _| {
        // The empty state's "Link pull request".
        open_panel(world)?.click(world, "emptyStateAction")?;
        world.sync()?;
        expect!(
            read_tab(world, PullRequests::link_open)?,
            "the link field is closed"
        );
        Ok(())
    });

    // A thread started on a pull request the user names (PullRequestThreadController).
    steps.step(
        &format!("the user pastes {Q} to start a pull request thread"),
        |world, c, _| {
            let (brick, field) = open_pull_request_thread(world)?;
            brick.click(world, "pullRequestThreadReference")?;
            brick.write(
                world,
                field,
                "text",
                ljos::prelude::Value::from(c[0].as_str()),
            )?;
            brick.press(world, "enter")?;
            world.sync()
        },
    );
    steps.step(
        &format!("the user (?:types|typed) {Q} to start a pull request thread"),
        |world, c, _| {
            let (brick, field) = open_pull_request_thread(world)?;
            brick.write(
                world,
                field,
                "text",
                ljos::prelude::Value::from(c[0].as_str()),
            )?;
            world.sync()
        },
    );
    steps.step("the user clears the reference", |world, _, _| {
        let brick = shown(world)?;
        let field = brick.item(world, "pullRequestThreadReference")?;
        brick.write(world, field, "text", ljos::prelude::Value::from(""))?;
        world.sync()
    });
    steps.step(
        "the pull request number is read as (\\d+)",
        |world, c, _| {
            let brick = shown(world)?;
            let wanted = format!("#{} · feature/tax to main", c[0]);
            world.wait_for_with(
                move |w| brick.shows(w, &wanted).unwrap_or(false),
                dialog_is("the pull request to be shown"),
            )?;
            expect!(
                choosable(world)?,
                "local and worktree cannot be chosen; the dialog is {}",
                show(&world.state("pullRequestThread"))
            );
            Ok(())
        },
    );
    steps.step("neither local nor worktree can be chosen", |world, _, _| {
        expect!(
            !choosable(world)?,
            "local or worktree can be chosen; the dialog is {}",
            show(&world.state("pullRequestThread"))
        );
        // Return does not start one either.
        shown(world)?.press(world, "enter")?;
        world.sync()?;
        expect!(
            asked(world, "git.preparePullRequestThread").is_empty(),
            "a checkout was prepared"
        );
        Ok(())
    });
    // The dialog resolves once the typing pauses, so it is resolving straight after.
    steps.step(
        "the user is told \"Resolving pull request...\" until its title and branches arrive",
        |world, _, _| {
            let brick = shown(world)?;
            expect!(
                brick.shows(world, "Resolving pull request...")?
                    && !brick.shows(world, "Add tax to the cart")?,
                "the dialog does not say it is resolving; it is {}",
                show(&world.state("pullRequestThread"))
            );
            expect!(
                !choosable(world)?,
                "local or worktree can be chosen while resolving"
            );
            Ok(())
        },
    );
    steps.step(
        "neither local nor worktree can be chosen until then",
        |world, _, _| {
            let brick = shown(world)?;
            world.wait_for_with(
                move |w| brick.shows(w, "Add tax to the cart").unwrap_or(false),
                dialog_is("the pull request to resolve"),
            )?;
            expect!(
                choosable(world)? && !brick.shows(world, "Resolving pull request...")?,
                "the resolved pull request cannot be chosen; the dialog is {}",
                show(&world.state("pullRequestThread"))
            );
            expect!(
                asked(world, "git.resolvePullRequest").len() == 1,
                "the pull request was asked for {} times",
                asked(world, "git.resolvePullRequest").len()
            );
            Ok(())
        },
    );
    steps.step(
        "the host answers that pull request (\\d+) does not exist",
        |world, c, _| {
            let reason = format!("GitHub has no pull request #{} in acme/shop.", c[0]);
            world
                .mc
                .part::<FakePullRequestThread>()
                .missing
                .insert(c[0].clone(), reason);
            Ok(())
        },
    );
    steps.step(
        "the user is told the host's reason in the dialog",
        |world, _, _| {
            let reason = world
                .mc
                .part::<FakePullRequestThread>()
                .missing
                .values()
                .next()
                .cloned()
                .unwrap_or_default();
            let brick = shown(world)?;
            world.wait_for_with(
                move |w| brick.shows(w, &reason).unwrap_or(false),
                dialog_is("the host's reason to be shown"),
            )
        },
    );
    // Choosing a worktree, with the MC still preparing it or failing to.
    steps.step(
        "the user chose to start a thread on pull request (\\d+) in a new worktree",
        |world, c, _| {
            world.mc.part::<FakePullRequestThread>().hold_prepare = true;
            start_in_worktree(world, &c[0])
        },
    );
    steps.step(
        "the user starts a thread on pull request (\\d+) in a new worktree",
        |world, c, _| start_in_worktree(world, &c[0]),
    );
    steps.step(
        &format!("the MC fails to prepare pull request (\\d+) saying {Q}"),
        |world, c, _| {
            world.mc.part::<FakePullRequestThread>().prepare_refusal = Some(c[1].clone());
            Ok(())
        },
    );
    steps.step(
        "the MC fails to prepare pull request (\\d+) without saying why",
        |world, _, _| {
            world.mc.part::<FakePullRequestThread>().prepare_refusal = Some(String::new());
            Ok(())
        },
    );
    steps.step("the checkout is still being prepared", |world, _, _| {
        world.wait_for("the checkout to be asked of the MC", |w| {
            !asked(w, "git.preparePullRequestThread").is_empty()
        })?;
        let state = world.state("pullRequestThread");
        expect!(
            state["step"] == "starting",
            "the dialog is {}",
            show(&state)
        );
        Ok(())
    });
    steps.step(
        &format!("the dialog says {Q} and cannot be cancelled"),
        |world, c, _| {
            let brick = shown(world)?;
            expect!(
                brick.shows(world, &c[0])?,
                "the dialog does not say {}; it is {}",
                c[0],
                show(&world.state("pullRequestThread"))
            );
            let cancel = brick.item(world, "pullRequestThreadCancel")?;
            expect!(
                !brick.flag(world, cancel, "enabled"),
                "Cancel can be pressed"
            );
            brick.press(world, "escape")?;
            world.dispatch("pullRequestThread.cancel", json!({}))?;
            world.sync()?;
            let field = brick.item(world, "pullRequestThreadReference")?;
            expect!(
                !world.state("pullRequestThread").is_null() && brick.flag(world, field, "visible"),
                "the dialog was closed while preparing"
            );
            Ok(())
        },
    );
    steps.step(
        "local and worktree cannot be chosen again",
        |world, _, _| {
            expect!(
                !choosable(world)?,
                "local or worktree can be chosen while preparing"
            );
            // Nor does the controller start a second one if asked.
            world.dispatch("pullRequestThread.start", json!({"mode": "local"}))?;
            world.sync()?;
            expect!(
                asked(world, "git.preparePullRequestThread").len() == 1,
                "a second checkout was asked for"
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the dialog stays open and says {Q}"),
        |world, c, _| {
            let brick = shown(world)?;
            let wanted = c[0].clone();
            world.wait_for_with(
                move |w| brick.shows(w, &wanted).unwrap_or(false),
                dialog_is(&format!("\"{}\" to be shown", c[0])),
            )?;
            let field = brick.item(world, "pullRequestThreadReference")?;
            expect!(
                brick.flag(world, field, "visible")
                    && asked(world, "orchestration.launchThread").is_empty(),
                "the dialog closed or a thread was started"
            );
            Ok(())
        },
    );
    steps.step(
        "the user can choose local or worktree again",
        |world, _, _| {
            expect!(
                choosable(world)?,
                "local and worktree cannot be chosen; the dialog is {}",
                show(&world.state("pullRequestThread"))
            );
            Ok(())
        },
    );
    steps.step(
        "the user sees the pull request's title and branches before choosing local or worktree",
        |world, _, _| {
            let brick = shown(world)?;
            world.wait_for_with(
                move |w| {
                    brick.shows(w, "Add tax to the cart").unwrap_or(false)
                        && brick.shows(w, "#42 · feature/tax to main").unwrap_or(false)
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
        world.mc.part::<FakePullRequests>().mentioned = c[1].clone();
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
            let line = format!("acme/shop · feature/tax → main · {wanted}");
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
                describe_review,
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
                describe_review,
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
                describe_review,
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
                describe_review,
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
                describe_review,
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
                describe_review,
            )
        },
    );
    steps.step(
        "the review page still shows pull request (\\d+) and sends nothing",
        |world, _, _| {
            world.wait_for_with(
                |w| read_review(w, |r| !r.online()).unwrap_or(false),
                describe_review,
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
                describe_review,
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
                describe_review,
            )
        },
    );
}

// Pull request links in the conversation, and the threads of a review
// (desktop-qt's PullRequestLinkPreviews and PullRequestThreadLinks).

const ISSUE_TEXT: &str = "The tax line is fixed in";

fn thread_links(world: &World) -> Outcome<ObjectId> {
    world
        .with::<RightPanel, _>(|p, _| p.thread_links())?
        .ok_or_else(|| Failure("the review has no linked threads".into()))
}

fn links_view(world: &World) -> Outcome<LinksView> {
    let obj = thread_links(world)?;
    ThreadLinks::view(world.engine(), obj)
        .ok_or_else(|| Failure("the linked threads are gone".into()))
}

fn describe_threads(world: &World) -> String {
    match links_view(world) {
        Ok(v) => format!("the review's threads are {v:?}"),
        Err(f) => f.0,
    }
}

/// A thread of "acme/shop" besides the scenario's, linking `links`.
fn add_thread(
    world: &mut World,
    id: &str,
    title: &str,
    links: Vec<Value>,
    archived: bool,
) -> Outcome {
    let mut row = json!({"id": id, "title": title, "projectId": PROJECT,
                         "pullRequests": links,
                         "createdAt": "2026-09-23T09:30:00Z", "updatedAt": "2026-09-23T09:30:00Z"});
    if archived {
        row["archivedAt"] = json!("2026-09-23T09:40:00Z");
    }
    world.mc.threads.insert(id.into(), row.clone());
    world.mc.send_row(id, &row);
    world.sync()
}

/// Opens the review of pull request `number` of "acme/shop", which no
/// thread links, beside the thread.
fn review_unlinked(world: &mut World, number: i64) -> Outcome {
    serve_review(&mut world.mc);
    world.dispatch(
        "rightPanel.reviewProject",
        json!({"key": format!("github.com/acme/shop#{number}")}),
    )?;
    world.sync()?;
    world.wait_for_with(
        |w| links_view(w).is_ok_and(|v| v.available && v.count >= 0),
        describe_threads,
    )
}

/// The conversation drawn as ThreadView, once.
fn thread_brick(world: &mut World) -> Outcome<Brick> {
    if let Ok(brick) = shown(world) {
        return Ok(brick);
    }
    Brick::show(
        world,
        "import QtQuick\nimport HalC2.Bricks\nThreadView { anchors.fill: parent }\n",
        820.0,
        700.0,
    )?;
    world.sync()?;
    shown(world)
}

/// Where the mentioned link is drawn in the conversation.
fn mention_point(world: &mut World) -> Outcome<(Brick, (f64, f64))> {
    let brick = thread_brick(world)?;
    let mentioned = world.mc.part::<FakePullRequests>().mentioned.clone();
    let root = brick
        .root(world)
        .ok_or_else(|| Failure("the conversation is not shown".into()))?;
    let pattern = fancy_regex::escape(&mentioned).into_owned();
    world.wait_for("the message to show its link", |w| {
        brick.text_point(w, root, "markdownProse", &pattern).is_ok()
    })?;
    let point = brick.text_point(world, root, "markdownProse", &pattern)?;
    Ok((brick, point))
}

fn read_text(world: &World, obj: ObjectId, name: &str) -> String {
    match world.engine().read_by_name(obj, name) {
        ljos::prelude::Value::String(s) => s.as_str().to_owned(),
        _ => String::new(),
    }
}

/// The link the user's pointer rests on, as the previews say.
fn previews_say(world: &World) -> String {
    let previews = world
        .with::<RightPanel, _>(|p, _| p.link_previews())
        .ok()
        .flatten();
    match previews {
        Some(obj) => format!(
            "the previews are at \"{}\" ({})",
            read_text(world, obj, "address"),
            read_text(world, obj, "status")
        ),
        None => "the panel has no link previews".into(),
    }
}

const NUMBER_URLS: [(&str, &str); 5] = [
    ("GitHub", "https://github.com/acme/shop/pull/42"),
    ("GitLab", "https://gitlab.com/acme/shop/-/merge_requests/42"),
    ("Forgejo", "https://codeberg.org/acme/shop/pulls/42"),
    (
        "Bitbucket",
        "https://bitbucket.org/acme/shop/pull-requests/42",
    ),
    (
        "Azure DevOps",
        "https://dev.azure.com/acme/shop/_git/shop/pullrequest/42",
    ),
];

fn open_number_menu(world: &mut World, host: &str) -> Outcome {
    let Some((_, url)) = NUMBER_URLS.iter().find(|(h, _)| *h == host) else {
        fail!("{host} is not a host the scenario knows");
    };
    world.dispatch(
        "pullRequest.linkMenu",
        json!({"url": url, "x": 300, "y": 200}),
    )?;
    world.sync()
}

/// "the user chooses {Q}" in the open thread picker.
pub fn pull_request_thread_chooses(world: &mut World, title: &str) -> Outcome<bool> {
    let Ok(view) = links_view(world) else {
        return Ok(false);
    };
    if !view.picker_open {
        return Ok(false);
    }
    let Some(candidate) = view.candidates.iter().find(|c| text(&c["title"]) == title) else {
        fail!("{}", describe_threads(world));
    };
    let obj = thread_links(world)?;
    ThreadLinks::choose(world.engine(), obj, &text(&candidate["id"]));
    world.sync()?;
    Ok(true)
}

/// "it says {Q}" of a review's linked threads.
pub fn pull_request_review_says(world: &mut World, wanted: &str) -> Outcome<bool> {
    if !wanted.starts_with("Linked from") || !links_view(world).is_ok_and(|v| v.available) {
        return Ok(false);
    }
    let wanted = wanted.to_owned();
    world.wait_for_with(
        move |w| links_view(w).is_ok_and(|v| v.label == wanted),
        describe_threads,
    )?;
    Ok(true)
}

fn register_links(steps: &mut Steps) {
    steps.step(
        &format!("a message in {Q} mentions {Q} of {Q}, which the message links to GitHub's page for issue (\\d+)"),
        |world, c, _| {
            look_at(world, &c[0])?;
            let url = format!("https://github.com/{}/issues/{}", c[2], c[3]);
            world.mc.part::<FakePullRequests>().mentioned = c[1].clone();
            start_run(world, 30, "running")?;
            add_item(
                world,
                "assistant_message",
                json!({"text": format!("{ISSUE_TEXT} [{}]({url}).", c[1])}),
            )?;
            settle_run(world, "completed", 30)
        },
    );
    steps.step(
        "the host knows (\\d+) as (a pull request|an issue)",
        |world, c, _| {
            if c[1] == "an issue" {
                let number: i64 = c[0].parse().unwrap_or(0);
                world
                    .mc
                    .part::<FakePullRequests>()
                    .unreadable
                    .insert(number);
            }
            Ok(())
        },
    );
    steps.step("the MC cannot read pull request (\\d+)", |world, c, _| {
        let number: i64 = c[0].parse().unwrap_or(0);
        world
            .mc
            .part::<FakePullRequests>()
            .unreadable
            .insert(number);
        Ok(())
    });
    steps.step("no project is checked out from that host", |world, _, _| {
        let mentioned = world.mc.part::<FakePullRequests>().mentioned.clone();
        let host = mentioned
            .split("://")
            .nth(1)
            .and_then(|rest| rest.split('/').next())
            .unwrap_or("")
            .to_owned();
        for project in world.mc.projects.values() {
            let key = text(&project["repositoryIdentity"]["canonicalKey"]);
            expect!(
                key.split('/').next() != Some(host.as_str()),
                "{} is checked out from {host}",
                text(&project["id"])
            );
        }
        Ok(())
    });
    steps.step("the user rests the pointer on that link", |world, _, _| {
        world.set_time_iso("2026-09-23T09:00:00Z")?;
        let (_, (x, y)) = mention_point(world)?;
        world.hover_at(1.0, 1.0)?;
        world.hover_at(x, y)?;
        world.sync()
    });
    steps.step(
        &format!(
            "a card shows {Q} #(\\d+), its state, its title, its author and when it was opened"
        ),
        |world, c, _| {
            let brick = shown(world)?;
            let wanted = [
                c[0].clone(),
                format!("#{}", c[1]),
                "Open".to_owned(),
                "Tax line fix".to_owned(),
                "Ada Lovelace (@ada)".to_owned(),
                "opened 3h ago".to_owned(),
            ];
            world.wait_for_with(
                move |w| wanted.iter().all(|t| brick.shows(w, t).unwrap_or(false)),
                previews_say,
            )
        },
    );
    steps.step(&format!("the card shows {Q}"), |world, c, _| {
        let brick = shown(world)?;
        let wanted = c[0].clone();
        world.wait_for_with(
            move |w| {
                w.with::<RightPanel, _>(|p, _| p.link_previews())
                    .ok()
                    .flatten()
                    .is_some_and(|obj| read_text(w, obj, "status") == "failed")
                    && brick.shows(w, &wanted).unwrap_or(false)
            },
            previews_say,
        )?;
        expect!(
            !brick.shows(world, "Tax line fix")?,
            "the card shows the pull request's title"
        );
        Ok(())
    });
    steps.step(
        "the user clicks that link( holding the modifier key)?",
        |world, c, _| {
            use ljos::item::{Modifiers, MouseButtons};
            let (_, (x, y)) = mention_point(world)?;
            let mut modifiers = Modifiers::CONTROL;
            if !c[0].is_empty() {
                modifiers |= Modifiers::SHIFT;
            }
            world.click_at_with(x, y, MouseButtons::LEFT, modifiers)?;
            world.sync()
        },
    );
    steps.step(
        "pull request (\\d+) (opens|does not open) in HAL-C2",
        |world, c, _| {
            let tab = format!("pull-request:github.com/acme/shop#{}", c[0]);
            if c[1] == "opens" {
                world.wait_for_with(
                    move |w| at(&w.state("panel"), "activeId") == &json!(tab),
                    |w| format!("{}; {}", show(&w.state("panel")), previews_say(w)),
                )?;
                expect!(
                    world.opened_urls().is_empty(),
                    "the browser opened {:?}",
                    world.opened_urls()
                );
            } else {
                let panel = world.state("panel");
                expect!(at(&panel, "activeId") != &json!(tab), "{}", show(&panel));
            }
            Ok(())
        },
    );
    steps.step(
        "it is not opened as a pull request of the public host",
        |world, _, _| {
            expect!(
                asked(world, "pullRequests.preview").is_empty(),
                "the MC was asked for {:?}",
                asked(world, "pullRequests.preview")
            );
            let panel = world.state("panel");
            expect!(
                !text(at(&panel, "activeId")).starts_with("pull-request:"),
                "{}",
                show(&panel)
            );
            Ok(())
        },
    );
    steps.step(
        "the user opens the menu of the number of a pull request of (GitHub|GitLab|Forgejo|Bitbucket|Azure DevOps)",
        |world, c, _| open_number_menu(world, &c[0]),
    );
    steps.step(
        "the clipboard cannot be written and the browser cannot be opened",
        |world, _, _| {
            world.set_clipboard_fails(true);
            world.set_browser_fails(true);
            Ok(())
        },
    );
    steps.step(
        &format!("the user chooses {Q} from the menu of a pull request number"),
        |world, c, _| {
            open_number_menu(world, "GitHub")?;
            let menu = world.state("menu");
            let items = at(&menu, "items").as_array().cloned().unwrap_or_default();
            let Some(item) = items.iter().find(|i| text(&i["label"]) == c[0]) else {
                fail!("the menu offers {}", show(&menu));
            };
            world.dispatch(
                "menu.select",
                json!({"requestId": at(&menu, "requestId"), "id": item["id"]}),
            )?;
            world.sync()
        },
    );
    steps.step(
        &format!("pull request (\\d+) is linked to {Q} and to {Q}"),
        |world, c, _| {
            look_at(world, &c[1])?;
            let number: i64 = c[0].parse().unwrap_or(0);
            let link = link_of("acme/shop", number, "manual", LINKED_AT);
            set_links(world, vec![link.clone()])?;
            add_thread(world, "thread-2", &c[2], vec![link], false)?;
            wait_for_row(world, number, true)
        },
    );
    steps.step("the user reads pull request (\\d+)", |world, c, _| {
        serve_review(&mut world.mc);
        open_review(world, c[0].parse().unwrap_or(0))
    });
    steps.step(
        "choosing it searches the threads for pull request (\\d+)",
        |world, c, _| {
            let obj = thread_links(world)?;
            ThreadLinks::search(world.engine(), obj);
            world.sync()?;
            let wanted = format!("https://github.com/acme/shop/pull/{}", c[0]);
            world.wait_for_with(
                move |w| {
                    w.with::<Palette, _>(|p, _| p.is_open() && p.query() == wanted)
                        .unwrap_or(false)
                },
                |w| {
                    w.with::<Palette, _>(|p, _| {
                        format!("the palette ({}) searches \"{}\"", p.is_open(), p.query())
                    })
                    .unwrap_or_default()
                },
            )
        },
    );
    steps.step(
        "pull request (\\d+) is linked to no thread",
        |world, c, _| {
            look_at(world, "Tax work")?;
            add_thread(world, "thread-2", "Tax review", Vec::new(), false)?;
            add_thread(world, "thread-3", "Old tax work", Vec::new(), true)?;
            review_unlinked(world, c[0].parse().unwrap_or(0))
        },
    );
    steps.step(
        "the user chooses to link pull request (\\d+) to a thread",
        |world, c, _| {
            let number: i64 = c[0].parse().unwrap_or(0);
            let key = format!("github.com/acme/shop#{number}");
            let reviewing =
                at(&world.state("panel"), "activeId") == &json!(format!("pull-request:{key}"));
            if !reviewing || links_view(world)?.count < 0 {
                if row_of(world, number).is_some() {
                    serve_review(&mut world.mc);
                    open_review(world, number)?;
                    world.wait_for_with(
                        |w| links_view(w).is_ok_and(|v| v.count >= 0),
                        describe_threads,
                    )?;
                } else {
                    review_unlinked(world, number)?;
                }
            }
            let obj = thread_links(world)?;
            ThreadLinks::set_picker_open(world.engine(), obj, true);
            world.sync()?;
            expect!(
                links_view(world)?.picker_open,
                "{}",
                describe_threads(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the user sees the active threads, newest first, with a way to search threads and projects",
        |world, _, _| {
            let titles = |w: &World| -> Vec<String> {
                links_view(w)
                    .map(|v| v.candidates.iter().map(|c| text(&c["title"])).collect())
                    .unwrap_or_default()
            };
            expect!(
                titles(world) == ["Tax review", "Tax work"],
                "{}",
                describe_threads(world)
            );
            let obj = thread_links(world)?;
            ThreadLinks::set_query(world.engine(), obj, "review");
            expect!(
                titles(world) == ["Tax review"],
                "{}",
                describe_threads(world)
            );
            // Each thread's project is searched too.
            ThreadLinks::set_query(world.engine(), obj, PROJECT);
            expect!(titles(world).len() == 2, "{}", describe_threads(world));
            ThreadLinks::set_query(world.engine(), obj, "");
            world.sync()
        },
    );
    steps.step("archived threads are not offered", |world, _, _| {
        let view = links_view(world)?;
        expect!(
            !view.candidates.iter().any(|c| c["id"] == "thread-3"),
            "{}",
            describe_threads(world)
        );
        Ok(())
    });
    steps.step(
        &format!("{Q} is shown as {Q} and cannot be chosen"),
        |world, c, _| {
            let view = links_view(world)?;
            let Some(candidate) = view.candidates.iter().find(|t| text(&t["title"]) == c[0]) else {
                fail!("{}", describe_threads(world));
            };
            expect!(
                c[1] == "Linked" && candidate["linked"] == true,
                "{}",
                describe_threads(world)
            );
            let before = link_commands(world);
            let obj = thread_links(world)?;
            ThreadLinks::choose(world.engine(), obj, &text(&candidate["id"]));
            world.sync()?;
            expect!(
                link_commands(world) == before,
                "choosing it changed the links"
            );
            Ok(())
        },
    );
    steps.step(
        "the menu offers to unlink pull request (\\d+) from this thread",
        |world, _, _| {
            let view = links_view(world)?;
            expect!(
                view.menu_label == "Unlink from this thread",
                "{}",
                describe_threads(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the MC refuses to (link|unlink) pull request (\\d+) (?:to|from) {Q}"),
        |world, c, _| {
            look_at(world, &c[2])?;
            let number: i64 = c[1].parse().unwrap_or(0);
            if c[0] == "link" {
                review_unlinked(world, number)?;
            } else {
                set_links(
                    world,
                    vec![link_of("acme/shop", number, "manual", LINKED_AT)],
                )?;
                wait_for_row(world, number, true)?;
                serve_review(&mut world.mc);
                open_review(world, number)?;
                world.wait_for_with(
                    |w| links_view(w).is_ok_and(|v| v.count >= 0),
                    describe_threads,
                )?;
            }
            world.mc.refusals.insert(
                format!("thread.pull-request.{}", c[0]),
                "Thread is archived".into(),
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user tries to (link|unlink) pull request (\\d+) (?:to|from) {Q}"),
        |world, c, _| {
            let unlink = c[0] == "unlink";
            expect!(
                links_view(world)?.linked_here == unlink,
                "{}",
                describe_threads(world)
            );
            let obj = thread_links(world)?;
            ThreadLinks::toggle_here(world.engine(), obj);
            world.sync()
        },
    );
}
