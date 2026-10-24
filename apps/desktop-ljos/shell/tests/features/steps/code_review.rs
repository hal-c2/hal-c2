//! The code-review plugin's own UI (features/source-control/agent-code-review.feature):
//! its real package from plugins/code-review, drawn by the desktop against a fake
//! of its MC part that publishes `reviews` and `threads` as the MC part does and
//! answers the calls the UI makes: desktop-qt's CodeReviewSteps.cpp.

use std::rc::Rc;

use hal_c2_shell::json;
use ljos::prelude::{ObjectId, Value};
use serde_json::{Map, Value as Json, json};

use super::mc_plugin::{
    FakePluginPart, add_plugin_thread, entry_of, fake_plugin_part, manifest, open_plugin_thread,
    package, publish_topic, run_fake_plugin, shown_named, switch_to_tab,
};
use super::plugin::{click_item, draws_text, find_named, shell};
use crate::fake_mc::{FakeMc, Rpc};
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::world::World;
use crate::{expect, fail};

const ID: &str = "code-review";
const REPOSITORY: &str = "acme/api";

fn package_dir() -> String {
    package("code-review")
}

/// The MC part's state: what it watches and its reviews, by key.
struct FakeCodeReview {
    settings: Json,
    watching: Json,
    activation: String,
    order: Vec<String>,
    reviews: std::collections::HashMap<String, Json>,
}

impl Default for FakeCodeReview {
    fn default() -> Self {
        Self {
            settings: Json::Null,
            watching: json!([]),
            activation: "selective".into(),
            order: Vec::new(),
            reviews: Default::default(),
        }
    }
}

fn state(mc: &mut FakeMc) -> &mut FakeCodeReview {
    mc.part::<FakeCodeReview>()
}

fn key(number: i64) -> String {
    format!("{REPOSITORY}#{number}")
}

/// What the MC part publishes: `reviews` for the page, and `threads`, each
/// review thread's review, for the header and the row mark.
fn publish(mc: &mut FakeMc) -> Outcome {
    let fake = state(mc);
    let mut reviews = Vec::new();
    let mut threads = Map::new();
    for each in &fake.order {
        let review = fake.reviews[each].clone();
        let thread = text(&review["threadId"]);
        if !thread.is_empty() {
            let mut fields = Map::new();
            for field in [
                "key",
                "repository",
                "number",
                "title",
                "url",
                "headBranch",
                "baseBranch",
                "status",
                "verdict",
                "error",
                "publishError",
            ] {
                if let Some(value) = review.get(field) {
                    fields.insert(field.into(), value.clone());
                }
            }
            threads.insert(thread, Json::Object(fields));
        }
        reviews.push(review);
    }
    let reviews = json!({"reviews": reviews, "problem": null, "unwatched": [],
                         "watching": fake.watching, "activation": fake.activation,
                         "checkedAt": "2026-10-07T09:00:00Z"});
    let part = fake_plugin_part(mc, ID)?;
    part.topics.insert("reviews".into(), reviews);
    part.topics.insert("threads".into(), Json::Object(threads));
    publish_topic(mc, ID, "reviews")?;
    publish_topic(mc, ID, "threads")
}

fn add<'a>(mc: &'a mut FakeMc, number: i64, status: &str, title: &str) -> &'a mut Json {
    let fake = state(mc);
    let at = key(number);
    if !fake.order.contains(&at) {
        fake.order.push(at.clone());
    }
    let mut review = json!({"key": at, "repository": REPOSITORY, "number": number,
        "title": title, "author": "octocat",
        "url": format!("https://github.com/{REPOSITORY}/pull/{number}"),
        "headBranch": format!("feature/{number}"), "baseBranch": "main",
        "headSha": format!("abc{number}"), "status": status, "comments": []});
    if status == "failed" {
        review["error"] = json!("The agent gave no findings.");
    }
    fake.reviews.insert(at.clone(), review);
    fake.reviews.get_mut(&at).unwrap_or_else(|| unreachable!())
}

fn comment(id: &str, line: i64, body: &str) -> Json {
    json!({"id": id, "path": "src/limits.ts", "line": line, "side": "new", "body": body,
           "dismissed": false})
}

/// A finished review with a verdict, a summary and two comments.
fn finish(review: &mut Json, status: &str, verdict: &str) {
    review["status"] = json!(status);
    review["verdict"] = json!(verdict);
    review["summary"] = json!("The limits are not checked per user.");
    review["comments"] = json!([
        comment("c1", 12, "This counts every user together."),
        comment("c2", 30, "The window never resets.")
    ]);
}

/// A review with a thread of its own, in the thread list unless the reviews
/// are only shown on the page.
fn give_thread(world: &mut World, key_of: &str, listed: bool) -> Outcome {
    let review = &mut state(&mut world.mc).reviews;
    let Some(review) = review.get_mut(key_of) else {
        fail!("no review {key_of}")
    };
    let number = review["number"].as_i64().unwrap_or(0);
    let thread = format!("t-review-{number}");
    review["threadId"] = json!(thread);
    let title = format!("Review {}", text(&review["key"]));
    add_plugin_thread(
        world,
        &thread,
        &title,
        json!({"id": ID, "kind": "review", "listed": listed}),
    )
}

/// The calls the UI makes, answered as the MC part answers them.
fn answer(mc: &mut FakeMc, rpc: &Rpc) -> Outcome {
    let method = text(&rpc.payload["method"]);
    let input = rpc.payload["input"].clone();
    let at = text(&input["key"]);
    if method == "settings" {
        let settings = state(mc).settings.clone();
        mc.reply(
            rpc,
            json!({"settings": settings,
                   "providers": [{"instanceId": "claudeAgent", "name": "Claude", "models": []}],
                   "repositories": [REPOSITORY]}),
        );
        return Ok(());
    }
    if method == "start" {
        let number = input["number"].as_i64().unwrap_or(0);
        add(mc, number, "running", "Add rate limits")["repository"] = input["repository"].clone();
        mc.reply(rpc, Json::Null);
        return publish(mc);
    }
    let Some(review) = state(mc).reviews.get_mut(&at) else {
        mc.refuse(rpc, &format!("no review {at}"));
        return Ok(());
    };
    if method == "dismiss" {
        let mut comments = review["comments"].as_array().cloned().unwrap_or_default();
        for each in &mut comments {
            if each["id"] == input["commentId"] {
                each["dismissed"] = input["dismissed"].clone();
            }
        }
        review["comments"] = json!(comments);
    } else if method == "publish" {
        review["status"] = json!("published");
        review["publishedAt"] = json!("2026-10-07T09:30:00Z");
    } else {
        mc.refuse(rpc, "no such call");
        return Ok(());
    }
    mc.reply(rpc, Json::Null);
    publish(mc)
}

/// The calls of `method` the UI made, with their input.
fn asked(mc: &FakeMc, method: &str) -> Vec<Json> {
    mc.calls
        .iter()
        .filter(|rpc| rpc.method == "plugins.call" && text(&rpc.payload["method"]) == method)
        .map(|rpc| rpc.payload["input"].clone())
        .collect()
}

fn saved_settings(mc: &FakeMc) -> Vec<Json> {
    mc.calls
        .iter()
        .filter(|rpc| rpc.method == "plugins.saveSettings")
        .map(|rpc| rpc.payload["settings"].clone())
        .collect()
}

/// The review's row on the page.
fn row(world: &mut World, number: i64) -> Outcome<ObjectId> {
    shown_named(world, &format!("codeReview:{}", key(number)))
}

fn text_of(world: &mut World, object_name: &str) -> Outcome<String> {
    let brick = shell(world)?;
    let found = shown_named(world, object_name)?;
    Ok(brick.text_of(world, found, "text"))
}

fn text_now(world: &World, object_name: &str, brick: crate::brick::Brick) -> String {
    super::mc_plugin::named(world, brick, object_name)
        .map(|found| brick.text_of(world, found, "text"))
        .unwrap_or_default()
}

fn wait_text(world: &mut World, object_name: &str, wanted: &str) -> Outcome {
    let brick = shell(world)?;
    shown_named(world, object_name)?;
    world.wait_for_with(
        |w| text_now(w, object_name, brick) == wanted,
        |w| {
            format!(
                "{object_name} to say {wanted}, not {}",
                text_now(w, object_name, brick)
            )
        },
    )
}

fn click(world: &mut World, target: ObjectId) -> Outcome {
    let brick = shell(world)?;
    world.wait_for_with(
        |w| brick.flag(w, target, "enabled"),
        |_| "the control to be enabled".to_owned(),
    )?;
    click_item(world, target)
}

fn parent_of(world: &World, target: ObjectId) -> Outcome<ObjectId> {
    match world.engine().read_by_name(target, "parent") {
        Value::Object(parent) => Ok(parent),
        _ => fail!("the item has no parent"),
    }
}

fn part_of(world: &mut World, root: ObjectId, name: &str) -> Outcome<ObjectId> {
    match find_named(world, root, name)? {
        Some(found) => Ok(found),
        None => fail!("{name} is not under it"),
    }
}

fn dismiss_button(world: &mut World) -> Outcome<ObjectId> {
    let comment = shown_named(world, "codeReviewComment:c1")?;
    part_of(world, comment, "codeReviewDismiss")
}

fn last_review(mc: &mut FakeMc) -> Outcome<String> {
    match state(mc).order.last() {
        Some(at) => Ok(at.clone()),
        None => fail!("no review"),
    }
}

pub fn register(steps: &mut Steps) {
    steps.step(
        &format!("an MC running the plugin {Q} with GitHub as its host"),
        |world, c, _| {
            expect!(c[0] == ID, "only {ID} is faked");
            let read = manifest(&package_dir())?;
            let mut settings = Map::new();
            for each in read["settings"].as_array().into_iter().flatten() {
                settings.insert(text(&each["key"]), each["default"].clone());
            }
            settings.insert("host".into(), json!("github"));
            let settings = Json::Object(settings);
            state(&mut world.mc).settings = settings.clone();
            let part = FakePluginPart {
                package: package_dir(),
                call: Some(Rc::new(answer)),
                ..FakePluginPart::default()
            };
            run_fake_plugin(world, entry_of(ID, &read, &settings), part)?;
            publish(&mut world.mc)
        },
    );
    // The MC part finds the repository's project itself; the client sees only
    // what it watches.
    steps.step(
        &format!("the project {Q} whose remote is {Q} on GitHub"),
        |_, _, _| Ok(()),
    );

    steps.step(
        "reviews of #(\\d+) running, #(\\d+) waiting to be published and #(\\d+) failed",
        |world, c, _| {
            let n = |i: usize| c[i].parse::<i64>().unwrap_or(0);
            add(&mut world.mc, n(0), "running", "Add rate limits");
            finish(
                add(&mut world.mc, n(1), "waiting", "Cache the session"),
                "waiting",
                "comment",
            );
            add(&mut world.mc, n(2), "failed", "Bump the parser");
            publish(&mut world.mc)
        },
    );
    steps.step(
        "#(\\d+), #(\\d+) and #(\\d+) are listed with their states",
        |world, c, _| {
            let brick = shell(world)?;
            let states = ["Reviewing", "Waiting to publish", "Failed"];
            let mut above = -1.0;
            for (i, wanted) in states.iter().enumerate() {
                let number = c[i].parse::<i64>().unwrap_or(0);
                let listed = row(world, number)?;
                // Each state's first review names it, above the review.
                let parent = parent_of(world, listed)?;
                expect!(
                    draws_text(world, parent, wanted)?,
                    "#{} is not under {wanted}",
                    c[i]
                );
                let y = brick.at(world, listed, 0.0, 0.0)?.1;
                expect!(y > above, "#{} is listed out of order", c[i]);
                above = y;
            }
            Ok(())
        },
    );

    steps.step(
        "the review of #(\\d+) is waiting with two comments",
        |world, c, _| {
            let number = c[0].parse::<i64>().unwrap_or(0);
            finish(
                add(&mut world.mc, number, "waiting", "Add rate limits"),
                "waiting",
                "request-changes",
            );
            publish(&mut world.mc)
        },
    );
    steps.step(
        &format!("the user opens the review of #(\\d+) on the {Q} page"),
        |world, c, _| {
            switch_to_tab(world, &c[1])?;
            let number = c[0].parse::<i64>().unwrap_or(0);
            let listed = row(world, number)?;
            click(world, listed)?;
            wait_text(
                world,
                "codeReviewTitle",
                &format!("#{}  Add rate limits", c[0]),
            )
        },
    );
    steps.step(
        "its verdict, summary and comments are shown",
        |world, _, _| {
            wait_text(world, "codeReviewVerdict", "Request changes")?;
            let summary = text_of(world, "codeReviewSummary")?;
            expect!(
                summary.contains("not checked per user"),
                "the summary says {summary}"
            );
            for (id, place) in [("c1", "src/limits.ts:12"), ("c2", "src/limits.ts:30")] {
                let shown = shown_named(world, &format!("codeReviewComment:{id}"))?;
                expect!(
                    draws_text(world, shown, place)?,
                    "comment {id} is not on {place}"
                );
            }
            Ok(())
        },
    );
    steps.step(
        "the user can publish it or dismiss comments",
        |world, _, _| {
            let brick = shell(world)?;
            // A changed review draws its comments again.
            let first = dismiss_button(world)?;
            click(world, first)?;
            world.wait_for_with(
                |w| {
                    shown_named_now(w, brick, "codeReviewComment:c1").is_some_and(|c| {
                        matches!(brick.find_under(w, c, "codeReviewDismiss"),
                        Ok(Some(b)) if brick.text_of(w, b, "text") == "Keep")
                    })
                },
                |_| "the comment to be dismissed".to_owned(),
            )?;
            let dismissed = asked(&world.mc, "dismiss")
                .first()
                .cloned()
                .unwrap_or(Json::Null);
            expect!(
                dismissed == json!({"key": key(13), "commentId": "c1", "dismissed": true}),
                "the MC was asked {}",
                show(&dismissed)
            );
            let publish_button = shown_named(world, "codeReviewPublish")?;
            click(world, publish_button)?;
            world.wait_for_with(
                |w| text_now(w, "codeReviewStatus", brick).starts_with("Published"),
                |w| text_now(w, "codeReviewStatus", brick),
            )?;
            expect!(
                asked(&world.mc, "publish") == [json!({"key": key(13)})],
                "the review was not published once"
            );
            Ok(())
        },
    );

    steps.step(
        &format!("the review of #(\\d+) finished with the verdict {Q}"),
        |world, c, _| {
            expect!(c[1] == "approved", "no verdict {}", c[1]);
            let number = c[0].parse::<i64>().unwrap_or(0);
            let review = add(&mut world.mc, number, "waiting", "Cache the session");
            finish(review, "waiting", "approve");
            give_thread(world, &key(number), true)?;
            publish(&mut world.mc)
        },
    );
    steps.step("the user opens the review's thread", |world, _, _| {
        let at = last_review(&mut world.mc)?;
        let thread = text(&state(&mut world.mc).reviews[&at]["threadId"]);
        open_plugin_thread(world, &thread)
    });
    steps.step(
        "the pull request, the verdict and the publish action are shown above the conversation",
        |world, _, _| {
            let brick = shell(world)?;
            let header = shown_named(world, "codeReviewHeader")?;
            let thread_header = shown_named(world, "pluginThreadHeader")?;
            expect!(
                find_named(world, thread_header, "codeReviewHeader")? == Some(header),
                "the header is not the thread's"
            );
            let says = |w: &World, name: &str| match brick.find_under(w, header, name) {
                Ok(Some(found)) => brick.text_of(w, found, "text"),
                _ => String::new(),
            };
            world.wait_for_with(
                |w| says(w, "codeReviewPullRequest") == "Review of #13 Cache the session",
                |w| says(w, "codeReviewPullRequest"),
            )?;
            expect!(
                says(world, "codeReviewVerdict") == "Approve",
                "the verdict is not shown"
            );
            let publish_button = part_of(world, header, "codeReviewPublish")?;
            expect!(
                brick.flag(world, publish_button, "visible"),
                "the review cannot be published"
            );
            Ok(())
        },
    );

    steps.step(&format!("{Q} shows reviews as {Q}"), |world, c, _| {
        state(&mut world.mc).settings["display"] = json!(c[1]);
        Ok(())
    });
    steps.step("#(\\d+) is reviewed", |world, c, _| {
        let number = c[0].parse::<i64>().unwrap_or(0);
        add(&mut world.mc, number, "running", "Add rate limits");
        let listed = state(&mut world.mc).settings["display"] != json!("page");
        give_thread(world, &key(number), listed)?;
        publish(&mut world.mc)
    });
    steps.step(
        "its thread is listed with the review mark and the state of the review",
        |world, _, _| {
            let marked = |world: &mut World, wanted: &str| -> Outcome {
                let brick = shell(world)?;
                world.wait_for_with(
                    |w| {
                        let Some(host) = super::mc_plugin::named(w, brick, "pluginRowMark") else {
                            return false;
                        };
                        let Ok(Some(mark)) = brick.find_under(w, host, "codeReviewRowMark") else {
                            return false;
                        };
                        matches!(brick.shows_under(w, mark, wanted), Ok(true))
                    },
                    |_| format!("the row mark to say {wanted}"),
                )
            };
            marked(world, "Reviewing")?;
            // The mark follows the review.
            let at = last_review(&mut world.mc)?;
            if let Some(review) = state(&mut world.mc).reviews.get_mut(&at) {
                finish(review, "waiting", "approve");
            }
            publish(&mut world.mc)?;
            marked(world, "Approve")
        },
    );

    steps.step(&format!("{Q} watches {Q} selectively"), |world, c, _| {
        let fake = state(&mut world.mc);
        fake.watching = json!([c[1]]);
        fake.activation = "selective".into();
        publish(&mut world.mc)
    });
    steps.step(
        &format!("the user starts a review of #(\\d+) from the {Q} tab"),
        |world, c, _| {
            let brick = shell(world)?;
            switch_to_tab(world, &c[1])?;
            let number = shown_named(world, "codeReviewStartNumber")?;
            brick.write(world, number, "text", Value::from(c[0].as_str()))?;
            let start = shown_named(world, "codeReviewStart")?;
            click(world, start)
        },
    );
    steps.step(
        "the review of #(\\d+) is listed as running",
        |world, c, _| {
            let n = c[0].parse::<i64>().unwrap_or(0);
            let started = json!({"repository": REPOSITORY, "number": n});
            world.wait_for_with(
                |w| asked(&w.mc, "start") == [started.clone()],
                |w| {
                    let first = asked(&w.mc, "start").first().cloned().unwrap_or(Json::Null);
                    format!(
                        "a review of #{} to be started, not {}",
                        c[0],
                        show(&Json::Array(vec![first]))
                    )
                },
            )?;
            let listed = row(world, n)?;
            let parent = parent_of(world, listed)?;
            expect!(
                draws_text(world, parent, "Reviewing")?,
                "#{} is not listed as running",
                c[0]
            );
            wait_text(
                world,
                "codeReviewTitle",
                &format!("#{}  Add rate limits", c[0]),
            )
        },
    );

    steps.step(
        "the user changed the review prompt and turned off REVIEW.md",
        |world, _, _| {
            let brick = shell(world)?;
            let settings = shown_named(world, "codeReviewSettings")?;
            world.wait_for_with(
                |w| brick.flag(w, settings, "loaded"),
                |_| "the settings to be read".to_owned(),
            )?;
            for (name, value) in [
                ("prompt", Value::from("Review it my way.")),
                ("readReviewMd", Value::Bool(false)),
            ] {
                expect!(
                    world
                        .engine()
                        .invoke_by_name(settings, "set", &[Value::from(name), value])
                        .is_ok(),
                    "the settings cannot be changed"
                );
            }
            world.sync()
        },
    );
    steps.step("the user resets the review prompt", |world, _, _| {
        let brick = shell(world)?;
        // The button sits below the fold of the settings page, out of the
        // mouse's reach.
        let reset = shown_named(world, "codeReviewResetPrompt")?;
        world.wait_for_with(
            |w| brick.flag(w, reset, "enabled"),
            |_| "the reset to be enabled".to_owned(),
        )?;
        expect!(
            world.engine().invoke_by_name(reset, "clicked", &[]).is_ok(),
            "the reset cannot be pressed"
        );
        world.sync()
    });
    steps.step("only the prompt is saved", |world, _, _| {
        world.wait_for_with(
            |w| !saved_settings(&w.mc).is_empty(),
            |_| "the settings to be saved".to_owned(),
        )?;
        let saved = saved_settings(&world.mc);
        expect!(
            saved == [json!({"prompt": null})],
            "the MC was sent {}",
            show(&Json::Array(saved.clone()))
        );
        Ok(())
    });
    steps.step(
        "REVIEW.md is still turned off, waiting to be saved",
        |world, _, _| {
            let brick = shell(world)?;
            let settings = shown_named(world, "codeReviewSettings")?;
            let plugins = text(&state(&mut world.mc).settings["prompt"]);
            // Read again after the save, the prompt is the plugin's and the
            // other change is made again.
            let values =
                |w: &World| json::from_value(w.engine(), &brick.read(w, settings, "values"));
            world.wait_for_with(
                |w| {
                    let values = values(w);
                    text(&values["prompt"]) == plugins
                        && values["readReviewMd"] == json!(false)
                        && brick.flag(w, settings, "dirty")
                },
                |w| {
                    format!(
                        "the settings to be read again with REVIEW.md off, not {}",
                        show(&values(w))
                    )
                },
            )
        },
    );

    steps.step(
        "GitHub, GitLab, Forgejo, Bitbucket and Azure DevOps are offered as hosts",
        |world, _, _| {
            let hosts = shown_named(world, "codeReviewHosts")?;
            for (value, label) in [
                ("github", "GitHub"),
                ("gitlab", "GitLab (coming later)"),
                ("forgejo", "Forgejo (coming later)"),
                ("bitbucket", "Bitbucket (coming later)"),
                ("azure-devops", "Azure DevOps (coming later)"),
            ] {
                let option = find_named(world, hosts, &format!("choice:{value}"))?;
                expect!(
                    match option {
                        Some(option) => draws_text(world, option, label)?,
                        None => false,
                    },
                    "{label} is not offered"
                );
            }
            Ok(())
        },
    );
    steps.step("only GitHub can be chosen today", |world, _, _| {
        let brick = shell(world)?;
        let settings = shown_named(world, "codeReviewSettings")?;
        let hosts = shown_named(world, "codeReviewHosts")?;
        let gitlab = part_of(world, hosts, "choice:gitlab")?;
        click_item(world, gitlab)?;
        world.sync()?;
        let values = json::from_value(world.engine(), &brick.read(world, settings, "values"));
        expect!(
            values["host"] == json!("github") && !brick.flag(world, settings, "dirty"),
            "GitLab was chosen"
        );
        let github = part_of(world, hosts, "choice:github")?;
        expect!(
            brick.flag(world, github, "chosen"),
            "GitHub is not the host"
        );
        Ok(())
    });
}

fn shown_named_now(w: &World, brick: crate::brick::Brick, name: &str) -> Option<ObjectId> {
    super::mc_plugin::named(w, brick, name)
}
