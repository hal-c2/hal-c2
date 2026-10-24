//! The pull requests page (PullRequestList), and the MC's side of it: what
//! `pullRequests.*` answers for its own environment (apps/server-ex
//! HalC2.PullRequests); the @desktop scenarios of
//! features/source-control/pull-request-list.feature: desktop-qt's
//! PullRequestListSteps.cpp.

use std::collections::HashMap;

use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::panel::RightPanel;
use hal_c2_shell::thread_view::pull_request_review::PullRequestReview;
use hal_c2_shell::thread_view::pull_requests::ThreadPullRequests;
use serde_json::{Value, json};

use crate::brick::{Brick, shown};
use crate::fake_mc::{FakeMc, Rpc};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

const VIEWER: &str = "sam";

/// The pull requests the MC lists. Another member has none of them.
#[derive(Default)]
struct FakeList {
    entries: Vec<Value>,
    refusal: String,
    /// Threads by pull request number, for `pullRequests.linkedThreads`.
    linked: HashMap<i64, Vec<Value>>,
    revision: i64,
    calls: Vec<(String, Value)>,
}

fn entry(
    project: &str,
    number: i64,
    title: &str,
    author: &str,
    state: &str,
    draft: bool,
    review_requested: bool,
) -> Value {
    json!({
        "provider": "github", "host": "github.com", "projectId": project,
        "projectTitle": project, "repository": project, "number": number,
        "title": title,
        "url": format!("https://github.com/{project}/pull/{number}"),
        "author": {"login": author},
        "headBranch": format!("topic-{number}"), "baseBranch": "main",
        "state": state, "isDraft": draft, "mergeability": "mergeable",
        "additions": 10, "deletions": 2,
        "createdAt": "2026-09-20T10:00:00Z",
        "updatedAt": format!("2026-09-2{}T10:00:00Z", number % 10),
        "viewerReviewRequested": review_requested, "labels": [],
    })
}

fn list(mc: &mut FakeMc, rpc: &Rpc) -> Value {
    let environment = mc.environment_id.clone();
    let fake = mc.part::<FakeList>();
    let state = text(&rpc.payload["state"]);
    let involvement = text(&rpc.payload["involvement"]);
    let draft = text(&rpc.payload["filters"]["draft"]);
    let project = text(&rpc.payload["projectId"]);
    let mut entries = Vec::new();
    if rpc.environment == environment {
        for pr in &fake.entries {
            let is_draft = pr["isDraft"].as_bool() == Some(true);
            if state != "all" && text(&pr["state"]) != state {
                continue;
            }
            if involvement == "authored" && text(&pr["author"]["login"]) != VIEWER {
                continue;
            }
            if involvement == "reviewing" && pr["viewerReviewRequested"].as_bool() != Some(true) {
                continue;
            }
            if (draft == "only" && !is_draft) || (draft == "hide" && is_draft) {
                continue;
            }
            if !project.is_empty() && text(&pr["projectId"]) != project {
                continue;
            }
            entries.push(pr.clone());
        }
    }
    json!({"viewers": {"github.com": VIEWER}, "providers": [], "entries": entries,
           "errors": [], "truncated": false, "nextCursors": {}})
}

fn send_revision(mc: &FakeMc, id: i64, revision: i64) {
    mc.send(&json!({"t": "pullRequestRefreshes", "id": id, "revision": revision}));
}

fn extension(mc: &mut FakeMc) {
    mc.on_rpc("pullRequests.", |mc, rpc| {
        mc.part::<FakeList>()
            .calls
            .push((rpc.method.clone(), rpc.payload.clone()));
        match rpc.method.as_str() {
            "pullRequests.list" => {
                let refusal = mc.part::<FakeList>().refusal.clone();
                if !refusal.is_empty() && rpc.environment == mc.environment_id {
                    mc.refuse_with(
                        rpc,
                        &refusal,
                        json!({"_tag": "PullRequestUnavailableError"}),
                    );
                    return Ok(());
                }
                let answer = list(mc, rpc);
                mc.reply(rpc, answer);
            }
            "pullRequests.invalidate" => {
                let fake = mc.part::<FakeList>();
                fake.revision += 1;
                let revision = fake.revision;
                mc.reply(rpc, json!({}));
                for id in mc.subscribers("pullRequestRefreshes") {
                    send_revision(mc, id, revision);
                }
            }
            "pullRequests.linkedThreads" => {
                let number = rpc.payload["number"].as_i64().unwrap_or(0);
                let threads = mc
                    .part::<FakeList>()
                    .linked
                    .get(&number)
                    .cloned()
                    .unwrap_or_default();
                mc.reply(rpc, json!({"threads": threads}));
            }
            _ => mc.reply(rpc, Value::Null),
        }
        Ok(())
    });
    mc.on_shape("pullRequestRefreshes", |mc, id, _| {
        let revision = mc.part::<FakeList>().revision;
        send_revision(mc, id, revision);
        Ok(())
    });
}

fn page(world: &World) -> Value {
    world.state("pullRequestList")
}

/// The rows of the page's groups.
fn rows(world: &World) -> Vec<Value> {
    page(world)["groups"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|group| group["rows"].as_array().cloned().unwrap_or_default())
        .collect()
}

/// The listed rows as "<repository>#<number>".
pub fn listed(world: &World) -> Vec<String> {
    rows(world)
        .iter()
        .map(|row| {
            format!(
                "{}#{}",
                text(&row["repository"]),
                row["number"].as_i64().unwrap_or(0)
            )
        })
        .collect()
}

pub fn row_key(world: &World, number: i64) -> Outcome<String> {
    match rows(world)
        .iter()
        .find(|row| row["number"].as_i64() == Some(number))
    {
        Some(row) => Ok(text(&row["key"])),
        None => fail!("#{number} is not listed: {}", show(&page(world))),
    }
}

fn calls(world: &mut World, method: &str) -> usize {
    world
        .mc
        .part::<FakeList>()
        .calls
        .iter()
        .filter(|(called, _)| called == method)
        .count()
}

pub fn open_page(world: &mut World) -> Outcome {
    world.dispatch("pullRequests.open", json!({}))?;
    world.wait_for_with(
        |w| {
            let page = page(w);
            page["open"] == true && page["loading"] != true
        },
        |w| format!("the pull requests page to load; it is {}", show(&page(w))),
    )
}

pub fn expect_listed(world: &mut World, wanted: &[&str]) -> Outcome {
    let mut expected: Vec<String> = wanted.iter().map(|s| (*s).to_owned()).collect();
    expected.sort();
    let again = expected.clone();
    world.wait_for_with(
        move |w| {
            let mut now = listed(w);
            now.sort();
            now == again && page(w)["loading"] != true
        },
        move |w| {
            format!(
                "{} to be listed; the page is {}",
                expected.join(", "),
                show(&page(w))
            )
        },
    )
}

const OPEN: [&str; 3] = ["acme/shop#12", "acme/api#7", "acme/api#9"];

fn filter(world: &mut World, name: &str, value: &str) -> Outcome {
    world.dispatch(
        "pullRequestList.filter",
        json!({"name": name, "value": value}),
    )
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);

    steps.step(
        &format!("a connected environment with the GitHub projects {Q} and {Q}"),
        |world, c, _| {
            for name in c.iter() {
                world.mc.projects.insert(
                    name.clone(),
                    json!({"id": name, "title": name, "workspaceRoot": format!("/work/{name}"),
                           "scripts": []}),
                );
            }
            world.mc.part::<FakeList>().entries = vec![
                entry(
                    &c[0],
                    12,
                    "Fix tax rounding",
                    "octocat",
                    "open",
                    false,
                    false,
                ),
                entry(&c[1], 7, "Add rate limits", VIEWER, "open", false, false),
                entry(&c[1], 9, "Retry webhooks", "hubot", "open", true, true),
                entry(
                    &c[0],
                    3,
                    "Drop the old cart",
                    VIEWER,
                    "merged",
                    false,
                    false,
                ),
            ];
            world.connect()?;
            world.sync()
        },
    );
    // The MC's own gh is the fake's; nothing to set up on the desktop.
    steps.step(
        "the GitHub CLI is installed and signed in",
        |_, _, _| Ok(()),
    );

    // The project's open pull requests beside a thread: the right panel's
    // Pull requests tab (ThreadPullRequests, PullRequestsPanel).
    steps.step(
        "the user adds a pull requests tab to the right panel",
        |world, _, _| {
            let (project, id) = ("acme/shop", "t-tax");
            let row = json!({"id": id, "title": "Tax work", "projectId": project,
                             "pullRequests": [],
                             "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"});
            world.mc.threads.insert(id.into(), row.clone());
            world.mc.send_row(id, &row);
            world.sync()?;
            let key = format!("{}:{id}", world.mc.environment_id);
            let route = Route::Thread(key.clone());
            world.with::<Navigation, _>(|n, engine| n.open(engine, route))?;
            world.wait_for("the thread's panel", move |w| {
                w.state("panel")["threadKey"] == json!(key)
            })?;
            world.dispatch("rightPanel.add", json!({"kind": "pull-requests"}))?;
            world.sync()?;
            Brick::show(
                world,
                "import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\nPullRequestsPanel { source: Panel.pullRequests; anchors.fill: parent }\n",
                420.0,
                500.0,
            )
        },
    );
    steps.step(
        "the open pull requests of the project are listed",
        |world, _, _| {
            let open = |w: &World| {
                let obj = w
                    .with::<RightPanel, _>(|p, _| p.pull_requests())
                    .ok()
                    .flatten()?;
                ThreadPullRequests::read(w.engine(), obj, |t| t.project_open())
            };
            world.wait_for_with(
                |w| open(w).is_some_and(|rows| rows.len() == 1),
                |w| {
                    format!(
                        "the project's open pull requests; the tab has {}",
                        show(&json!(open(w)))
                    )
                },
            )?;
            // The thread's project only, and only what is open: not acme/api's, not the merged #3.
            let rows = open(world).unwrap_or_default();
            let first = rows.first().cloned().unwrap_or(Value::Null);
            expect!(
                first["number"].as_i64() == Some(12)
                    && first["title"] == "Fix tax rounding"
                    && first["key"] == "github.com/acme/shop#12",
                "the tab lists {}",
                show(&json!(rows))
            );
            let brick = shown(world)?;
            world.wait_for("the tab to draw them", move |w| {
                brick.shows(w, "Open in this project").unwrap_or(false)
                    && brick.shows(w, "Fix tax rounding").unwrap_or(false)
            })?;
            expect!(
                brick.shows(world, "#12 · octocat · topic-12 → main")?,
                "the pull request's number, author and branches are not drawn"
            );
            Ok(())
        },
    );
    steps.step("opening one shows its review", |world, _, _| {
        let brick = shown(world)?;
        brick.click(world, "projectPullRequest-12")?;
        world.sync()?;
        let panel = world.state("panel");
        expect!(
            panel["activeId"] == "pull-request:github.com/acme/shop#12",
            "the panel is {}",
            show(&panel)
        );
        let review = world
            .with::<RightPanel, _>(|p, _| p.review())?
            .ok_or_else(|| crate::harness::Failure("the panel has no review".into()))?;
        let (number, key) =
            PullRequestReview::read(world.engine(), review, |r| (r.number(), r.key()))
                .ok_or_else(|| crate::harness::Failure("the review is busy".into()))?;
        expect!(
            number == 12 && key == "github.com/acme/shop#12",
            "the review is of {key}"
        );
        // It reads the pull request from its host.
        world.wait_for("the review to read the pull request", |w| {
            w.mc.calls
                .iter()
                .any(|rpc| rpc.method == "pullRequests.detail")
        })
    });

    steps.step("the user opens the pull requests page", |world, _, _| {
        open_page(world)
    });
    steps.step("the user is on the pull requests page", |world, _, _| {
        open_page(world)?;
        expect_listed(world, &OPEN)
    });
    steps.step(
        "pull requests from every project are listed with state, involvement, project and filter choices",
        |world, _, _| {
            expect_listed(world, &OPEN)?;
            let now = page(world);
            let filters = &now["filters"];
            expect!(
                filters["state"] == "open"
                    && filters["involvement"] == "all"
                    && filters.get("draft").is_some()
                    && filters.get("review").is_some()
                    && filters.get("checks").is_some(),
                "the filters are {}",
                show(filters)
            );
            let labels = |key: &str| -> Vec<String> {
                now[key]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|item| text(&item["label"]))
                    .collect()
            };
            let projects = labels("projects");
            expect!(
                projects.iter().any(|p| p == "acme/shop") && projects.iter().any(|p| p == "acme/api"),
                "the project choices are {}",
                projects.join(", ")
            );
            let groups = labels("groups");
            expect!(
                groups == ["Authored", "Review requested", "Others"],
                "the groups are {}",
                groups.join(", ")
            );
            Ok(())
        },
    );
    steps.step(
        "the user's filter choices are kept for next time",
        |world, _, _| {
            filter(world, "involvement", "authored")?;
            expect_listed(world, &["acme/api#7"])?;
            world.restart()?;
            world.connect()?;
            world.wait_for_with(
                |w| at(&page(w), "filters.involvement") == "authored",
                |w| {
                    format!(
                        "the choice to be kept; after a restart the page is {}",
                        show(&page(w))
                    )
                },
            )
        },
    );

    steps.step(
        "the user filters pull requests to (drafts only|drafts hidden|merged ones|open ones)",
        |world, c, _| match c[0].as_str() {
            "drafts only" => filter(world, "draft", "only"),
            "drafts hidden" => filter(world, "draft", "hide"),
            "merged ones" => filter(world, "state", "merged"),
            _ => filter(world, "state", "open"),
        },
    );
    steps.step(
        "no pull request matches the chosen filters",
        |world, _, _| filter(world, "state", "closed"),
    );
    steps.step("the projects have no pull requests", |world, _, _| {
        world.mc.part::<FakeList>().entries.clear();
        Ok(())
    });
    steps.step(
        &format!("the user is told {Q} and to widen the filters"),
        |world, c, _| {
            let title = c[0].clone();
            world.wait_for_with(
                move |w| at(&page(w), "empty.title") == &json!(title),
                |w| format!("the page to say \"{}\"; it is {}", c[0], show(&page(w))),
            )?;
            expect!(
                text(at(&page(world), "empty.body")).contains("Widen"),
                "the page is {}",
                show(&page(world))
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the pull requests page says {Q}"),
        |world, c, _| {
            let said = c[0].clone();
            let says = move |w: &World| {
                let now = page(w);
                let wanted = json!(said);
                at(&now, "empty.title") == &wanted
                    || at(&now, "error.title") == &wanted
                    || at(&now, "notice.text") == &wanted
                    || now["problems"]
                        .as_array()
                        .is_some_and(|problems| problems.contains(&wanted))
            };
            world.wait_for_with(says, |w| {
                format!("the page to say \"{}\"; it is {}", c[0], show(&page(w)))
            })
        },
    );
    steps.step(
        "the (open|merged|draft|non-draft) pull requests are listed",
        |world, c, _| match c[0].as_str() {
            "open" => expect_listed(world, &OPEN),
            "merged" => expect_listed(world, &["acme/shop#3"]),
            "draft" => expect_listed(world, &["acme/api#9"]),
            _ => expect_listed(world, &["acme/shop#12", "acme/api#7"]),
        },
    );

    // Environments and failures.
    steps.step(
        &format!("the MC cannot list pull requests, saying {Q}"),
        |world, c, _| {
            world.mc.part::<FakeList>().refusal = c[0].clone();
            Ok(())
        },
    );
    steps.step("the MC can list pull requests again", |world, _, _| {
        world.mc.part::<FakeList>().refusal.clear();
        Ok(())
    });
    steps.step(
        &format!("the pull requests page shows the error {Q} with a retry"),
        |world, c, _| {
            let message = c[0].clone();
            world.wait_for_with(
                move |w| at(&page(w), "error.message") == &json!(message),
                |w| format!("the page to show the error; it is {}", show(&page(w))),
            )?;
            expect!(
                at(&page(world), "error.title") == "Could not load pull requests"
                    && listed(world).is_empty(),
                "the page is {}",
                show(&page(world))
            );
            Ok(())
        },
    );
    steps.step(
        "the user (?:refreshes|retries) the pull requests page",
        |world, _, _| world.dispatch("pullRequestList.refresh", json!({})),
    );
    steps.step(
        "the MC forgets what it knew and the list is read again",
        |world, _, _| {
            let before = calls(world, "pullRequests.list");
            world.wait_for("the list to be read again", move |w| {
                w.mc.peek::<FakeList>().is_some_and(|f| {
                    f.calls
                        .iter()
                        .filter(|(m, _)| m == "pullRequests.list")
                        .count()
                        > before
                })
            })?;
            expect!(
                calls(world, "pullRequests.invalidate") >= 1,
                "the MC was not asked to forget"
            );
            Ok(())
        },
    );
    steps.step("a pull request is merged from HAL-C2", |world, _, _| {
        let fake = world.mc.part::<FakeList>();
        fake.calls.clear();
        fake.revision += 1;
        let revision = fake.revision;
        if let Some(first) = fake.entries.first_mut() {
            first["state"] = json!("merged");
        }
        for id in world.mc.subscribers("pullRequestRefreshes") {
            send_revision(&world.mc, id, revision);
        }
        Ok(())
    });
    steps.step("the page lists it no longer", |world, _, _| {
        expect_listed(world, &["acme/api#7", "acme/api#9"])
    });
    steps.step("the user leaves the pull requests page", |world, _, _| {
        world.dispatch("settings.open", json!({}))?;
        world.sync()
    });
    steps.step(
        "the desktop stops listening for pull request changes",
        |world, _, _| {
            world.wait_for("the pull request changes to be unsubscribed", |w| {
                w.mc.subscribers("pullRequestRefreshes").is_empty()
            })
        },
    );

    // Opening a pull request.
    steps.step(
        &format!("the thread {Q} works on #(\\d+)"),
        |world, c, _| {
            let id = format!("thread-{}", c[0]);
            let row = json!({"id": id, "projectId": "acme/shop", "title": c[0],
                             "createdAt": "2026-09-20T10:00:00Z", "updatedAt": "2026-09-20T10:00:00Z"});
            world.mc.threads.insert(id.clone(), row.clone());
            world.mc.send_row(&id, &row);
            world
                .mc
                .part::<FakeList>()
                .linked
                .entry(c[1].parse().unwrap_or(0))
                .or_default()
                .push(json!({"id": id, "projectId": "acme/shop", "title": c[0],
                             "archivedAt": null}));
            Ok(())
        },
    );
    steps.step(
        "the user opens #(\\d+) from the pull requests page",
        |world, c, _| {
            let key = row_key(world, c[0].parse().unwrap_or(0))?;
            world.dispatch("pullRequestList.open", json!({"key": key}))
        },
    );
    // The dialog that starts a thread on it, rather than a line that reflows the list.
    steps.step(
        "the user is offered to start a thread on #(\\d+)",
        |world, c, _| {
            let url = format!("https://github.com/acme/api/pull/{}", c[0]);
            let wanted = url.clone();
            world.wait_for_with(
                move |w| at(&w.state("pullRequestThread"), "reference") == &json!(wanted),
                |w| {
                    format!(
                        "the dialog to be on {url}; it is {}",
                        show(&w.state("pullRequestThread"))
                    )
                },
            )?;
            expect!(
                page(world).get("notice").is_none_or(Value::is_null),
                "the page shows a notice: {}",
                show(&page(world))
            );
            Ok(())
        },
    );
    steps.step(
        "the user opens #(\\d+) on GitHub from the pull requests page",
        |world, c, _| {
            let key = row_key(world, c[0].parse().unwrap_or(0))?;
            world.dispatch("pullRequestList.openOnHost", json!({"key": key}))
        },
    );
}
