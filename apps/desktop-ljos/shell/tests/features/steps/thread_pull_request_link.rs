//! Pointing a thread at a pull request from the conversation, and what its
//! Pull requests tab shows of the branch's own (features/threads/
//! pull-request-links.feature). The links themselves are the MC's
//! (pull_request.rs projects `thread.pull-request.link` and `.unlink`);
//! here the MC also puts the branch's pull request back once no link of the
//! user's is left, as its sync does: desktop-qt's
//! ThreadPullRequestLinkSteps.cpp.

use std::rc::Rc;

use hal_c2_shell::controllers::panel::RightPanel;
use hal_c2_shell::thread_view::pull_requests::{PullRequests, ThreadPullRequests};
use hal_c2_shell::thread_view::rows::RowSource;
use ljos::prelude::ObjectId;
use serde_json::{Value, json};

use super::stream::{FakeStreams, look};
use crate::fake_mc::FakeMc;
use crate::harness::{Failure, Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

const ID: &str = "t-cart";
const LINK_URL: &str = "https://github.com/acme/shop/pull/41";

fn tab_object(world: &World) -> Outcome<ObjectId> {
    world
        .with::<RightPanel, _>(|p, _| p.pull_requests())?
        .ok_or_else(|| Failure("the panel has no Pull requests tab".into()))
}

fn read_tab<R>(world: &World, f: impl FnOnce(&PullRequests) -> R) -> Outcome<R> {
    let obj = tab_object(world)?;
    ThreadPullRequests::read(world.engine(), obj, f)
        .ok_or_else(|| Failure("the Pull requests tab is busy".into()))
}

fn listed(world: &World) -> Vec<i64> {
    read_tab(world, |tab| {
        (0..tab.row_count())
            .map(|row| match tab.data(row, "number") {
                ljos::prelude::Value::Int(n) => i64::from(n),
                _ => 0,
            })
            .collect()
    })
    .unwrap_or_default()
}

fn describe(world: &World) -> String {
    let numbers: Vec<String> = listed(world).iter().map(i64::to_string).collect();
    let (problem, notice) =
        read_tab(world, |t| (t.problem().to_owned(), t.notice().to_owned())).unwrap_or_default();
    format!(
        "the tab lists [{}] (problem \"{problem}\", notice \"{notice}\")",
        numbers.join(", ")
    )
}

fn link(number: i64, source: &str) -> Value {
    json!({"host": "github.com", "repository": "acme/shop", "number": number,
           "url": format!("https://github.com/acme/shop/pull/{number}"), "source": source,
           "linkedAt": "2026-09-23T09:05:00Z", "snapshot": null, "stack": null})
}

fn extension(mc: &mut FakeMc) {
    // The sync links the branch's pull request while the thread has no other.
    mc.effects.push(Rc::new(|mc, command| {
        if command["type"] != "thread.pull-request.unlink" {
            return;
        }
        let id = text(&command["threadId"]);
        let Some(mut row) = mc.threads.get(&id).cloned() else {
            return;
        };
        let branch = row["branchPullRequest"].clone();
        let linked = row["pullRequests"]
            .as_array()
            .is_some_and(|l| !l.is_empty());
        if !branch.is_object() || linked {
            return;
        }
        row["pullRequests"] = json!([link(branch["number"].as_i64().unwrap_or(0), "created")]);
        mc.threads.insert(id.clone(), row.clone());
        mc.send_row(&id, &row);
    }));
}

fn show_tab(world: &mut World) -> Outcome {
    world.dispatch("rightPanel.add", json!({"kind": "pull-requests"}))?;
    world.sync()
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);

    steps.step(
        &format!("a connected environment with the thread {Q} on the branch {Q}"),
        |world, c, _| {
            world.mc.projects.insert(
                "shop".into(),
                json!({"id": "shop", "title": "shop", "workspaceRoot": "/work/shop",
                       "scripts": [],
                       "repositoryIdentity": {
                           "canonicalKey": "github.com/acme/shop",
                           "locator": {"source": "git-remote", "remoteName": "origin",
                                       "remoteUrl": "https://github.com/acme/shop.git"},
                           "provider": "github", "owner": "acme", "name": "shop"}}),
            );
            world.mc.threads.insert(
                ID.into(),
                json!({"id": ID, "title": c[0], "projectId": "shop", "branch": c[1],
                       "pullRequests": [],
                       "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"}),
            );
            world.connect()?;
            world.sync()?;
            let environment = world.mc.environment_id.clone();
            let streams = world.mc.part::<FakeStreams>();
            streams.thread = ID.into();
            streams.environment = environment.clone();
            look(world, &format!("{environment}:{ID}"), true)
        },
    );

    // From a link in the conversation.
    steps.step(
        &format!("{Q} shows a link to pull request (\\d+)"),
        |world, c, _| {
            expect!(
                c[1] == "41" && listed(world).is_empty(),
                "{}",
                describe(world)
            );
            // The secondary button on the link, as Markdown.qml reports it.
            world.dispatch("link.menu", json!({"url": LINK_URL, "x": 300, "y": 200}))
        },
    );
    steps.step(
        "the user links pull request (\\d+) to the thread from that link",
        |world, _, _| {
            let menu = world.state("menu");
            let offered = at(&menu, "items")
                .as_array()
                .is_some_and(|items| items.iter().any(|i| i["id"] == "link-pull-request"));
            expect!(offered, "the link's menu is {}", show(&menu));
            world.dispatch(
                "menu.select",
                json!({"requestId": at(&menu, "requestId"), "id": "link-pull-request"}),
            )
        },
    );
    steps.step(
        &format!("{Q} is linked to pull request (\\d+)"),
        |world, c, _| {
            let number: i64 = c[1].parse().unwrap_or(0);
            world.wait_for_with(move |w| listed(w) == [number], describe)?;
            let sent = world.mc.commands.iter().any(|command| {
                command["type"] == "thread.pull-request.link"
                    && command["threadId"] == ID
                    && command["number"].as_i64() == Some(number)
                    && command["source"] == "manual"
            });
            expect!(sent, "the MC has {}", world.describe_commands());
            Ok(())
        },
    );

    // Unlinking.
    steps.step(
        &format!("{Q} was linked by hand to pull request (\\d+)"),
        |world, c, _| {
            let number: i64 = c[1].parse().unwrap_or(0);
            let Some(mut row) = world.mc.threads.get(ID).cloned() else {
                fail!("no thread {ID}");
            };
            // The branch has its own pull request, 40; the user's link took
            // its place.
            row["branchPullRequest"] = json!({"host": "github.com", "repository": "acme/shop",
                "number": 40, "url": "https://github.com/acme/shop/pull/40"});
            row["pullRequests"] = json!([link(number, "manual")]);
            world.mc.threads.insert(ID.into(), row.clone());
            world.mc.send_row(ID, &row);
            show_tab(world)?;
            world.wait_for_with(move |w| listed(w) == [number], describe)
        },
    );
    steps.step(
        "the user unlinks pull request (\\d+) from the thread",
        |world, c, _| {
            let number: i64 = c[0].parse().unwrap_or(0);
            let key = read_tab(world, |tab| {
                (0..tab.row_count()).find_map(|row| match tab.data(row, "number") {
                    ljos::prelude::Value::Int(n) if i64::from(n) == number => {
                        Some(tab.data(row, "linkKey").to_js_string())
                    }
                    _ => None,
                })
            })?;
            let Some(key) = key else {
                fail!("{}", describe(world));
            };
            let obj = tab_object(world)?;
            ThreadPullRequests::update(world.engine(), obj, |tab| tab.unlink(&key));
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} shows the pull request for {Q} again"),
        |world, _, _| world.wait_for_with(|w| listed(w) == [40], describe),
    );

    // An environment too old for branch pull requests.
    steps.step(
        "the environment does not look for branch pull requests",
        |world, _, _| {
            if let Some(capabilities) = world.mc.capabilities.as_object_mut() {
                capabilities.insert("threadPullRequests".into(), json!(false));
            }
            world.mc.send_snapshot();
            world.sync()
        },
    );
    steps.step(&format!("the user looks at {Q}"), |world, _, _| {
        show_tab(world)
    });
    steps.step(
        "the user is told to update the server to see branch pull requests",
        |world, _, _| {
            // PullRequestsPanel.qml shows the tab's notice.
            let notice = read_tab(world, |t| t.notice().to_owned())?;
            expect!(
                notice == "Update this environment's server to see branch pull requests.",
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
}
