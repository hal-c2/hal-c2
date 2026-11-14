//! PullRequestReview's core: what it reads of a pull request and what it
//! sends back (PullRequestSteps, features/pull-requests/review.feature).

use serde_json::json;

use super::{DIFF_PATH, Done, Effect, Json, Review, Then, detail_of};

const ENVIRONMENT: &str = "env-a";

fn reference() -> Json {
    json!({"projectId": "p1", "host": "github.com", "repository": "acme/app", "number": 7})
}

/// The calls and posts it made: (method or path, payload, then).
fn asked(review: &mut Review) -> Vec<(String, Json, Then)> {
    review
        .take_effects()
        .into_iter()
        .filter_map(|e| match e {
            Effect::Call {
                environment,
                method,
                payload,
                then,
            } => {
                assert_eq!(environment, ENVIRONMENT);
                Some((method.to_owned(), payload, then))
            }
            Effect::Post { path, body, then } => Some((format!("POST {path}"), body, then)),
            _ => None,
        })
        .collect()
}

fn then_of(asked: &[(String, Json, Then)], method: &str) -> Then {
    asked
        .iter()
        .find(|(m, ..)| m == method)
        .map(|(.., then)| then.clone())
        .unwrap_or_else(|| panic!("{method} was asked"))
}

fn detail() -> Json {
    json!({
        "title": "Speed up",
        "body": "Faster.",
        "url": "https://github.com/acme/app/pull/7",
        "author": {"login": "ada"},
        "state": "open",
        "isDraft": false,
        "headBranch": "fast",
        "baseBranch": "main",
        "labels": [{"name": "perf"}],
        "reviewers": [{"login": "bob"}],
        "mergeability": "mergeable",
        "behindBy": 2,
        "checks": [{"name": "ci", "status": "passing", "description": "", "url": "u"}],
        "capabilities": {"actions": ["merge", "comment"], "mergeMethods": ["squash", "merge", "rebase"]},
        "mergeCapabilities": {"squash": true, "merge": false, "rebase": true},
    })
}

/// Shown and online: what it asked when it loaded.
fn loaded() -> (Review, Vec<(String, Json, Then)>) {
    let mut review = Review::new();
    review.set_online(true);
    review.set_active(true);
    review.set_pull_request(ENVIRONMENT, "p1", "github.com", "acme/app", 7);
    let asked = asked(&mut review);
    (review, asked)
}

fn ready() -> Review {
    let (mut review, asked) = loaded();
    review.answer(then_of(&asked, "pullRequests.detail"), Ok(detail()));
    review.take_effects();
    review.take_notes();
    review
}

#[test]
fn the_detail_shows_what_the_host_says() {
    let shown = detail_of(&detail());
    assert_eq!(shown["author"], "ada");
    assert_eq!(shown["stateLabel"], "Open");
    assert_eq!(shown["branches"], "fast → main");
    assert_eq!(shown["labels"], json!(["perf"]));
    assert_eq!(shown["reviewers"], json!(["bob"]));
    assert_eq!(shown["behindBy"], 2);
    assert_eq!(shown["canMerge"], true);
    assert_eq!(
        shown["mergeMethods"],
        json!(["squash", "rebase"]),
        "only what the repository allows"
    );

    let mut draft = detail();
    draft["isDraft"] = json!(true);
    draft["mergeCapabilities"] = json!({});
    let shown = detail_of(&draft);
    assert_eq!(
        (shown["state"].as_str(), shown["stateLabel"].as_str()),
        (Some("draft"), Some("Draft"))
    );
    assert_eq!(shown["canMerge"], false);
    assert_eq!(shown["mergeMethods"], json!(["squash", "merge", "rebase"]));

    let mut barred = detail();
    barred["viewerPermissions"] = json!({"actions": ["comment"]});
    assert_eq!(detail_of(&barred)["canMerge"], false);
    let mut merged = detail();
    merged["state"] = json!("merged");
    assert_eq!(detail_of(&merged)["stateLabel"], "Merged");
}

#[test]
fn a_shown_pull_request_reads_its_detail_activity_viewed_files_stack_and_code() {
    let (review, asked) = loaded();
    let methods: Vec<&str> = asked.iter().map(|(m, ..)| m.as_str()).collect();
    assert_eq!(
        methods,
        [
            "pullRequests.detail",
            "pullRequests.stack",
            "pullRequests.activity",
            "pullRequests.filesViewed",
            "POST /api/pull-requests/diff",
        ]
    );
    assert!(asked.iter().all(|(_, payload, _)| *payload == reference()));
    assert_eq!(review.status(), "loading");
    assert_eq!(review.code_status(), "loading");
    assert_eq!(review.key(), "github.com/acme/app#7");
}

#[test]
fn it_reads_nothing_until_shown_and_online() {
    let mut review = Review::new();
    review.set_pull_request(ENVIRONMENT, "p1", "github.com", "acme/app", 7);
    assert!(asked(&mut review).is_empty());
    review.set_active(true);
    assert!(asked(&mut review).is_empty(), "offline");
    review.set_online(true);
    assert_eq!(asked(&mut review).len(), 5);
    // Once.
    review.set_active(false);
    review.set_active(true);
    assert!(asked(&mut review).is_empty());
    review.reload();
    assert_eq!(asked(&mut review).len(), 5);
}

#[test]
fn back_online_a_failed_read_is_read_again() {
    let (mut review, asked_first) = loaded();
    review.answer(
        then_of(&asked_first, "pullRequests.detail"),
        Err("unreachable".into()),
    );
    assert_eq!(
        (review.status(), review.message()),
        ("error", "unreachable")
    );
    review.set_online(false);
    review.set_online(true);
    assert_eq!(asked(&mut review).len(), 5);
}

#[test]
fn the_code_is_read_a_slice_at_a_time() {
    let (mut review, first) = loaded();
    review.answer(
        then_of(&first, "POST /api/pull-requests/diff"),
        Ok(json!({"patch": "diff --git a/x b/x", "nextCursor": "c2"})),
    );
    let effects = review.take_effects();
    assert_eq!(effects[0], Effect::Patch("diff --git a/x b/x".into()));
    let Effect::Post { path, body, then } = &effects[1] else {
        panic!("{effects:?}");
    };
    assert_eq!(*path, DIFF_PATH);
    assert_eq!(body["cursor"], "c2");
    assert_eq!(body["number"], 7);
    assert_eq!(review.code_status(), "loading");
    review.answer(
        then.clone(),
        Ok(json!({"patch": "diff --git a/y b/y\n", "nextCursor": ""})),
    );
    assert_eq!(
        review.take_effects(),
        vec![Effect::Patch(
            "diff --git a/x b/x\ndiff --git a/y b/y\n".into()
        )]
    );
    assert_eq!(review.code_status(), "ready");
}

#[test]
fn a_reply_for_the_pull_request_before_is_dropped() {
    let (mut review, first) = loaded();
    review.set_pull_request(ENVIRONMENT, "p1", "github.com", "acme/app", 8);
    assert!(review.take_effects().contains(&Effect::Clear));
    review.answer(then_of(&first, "pullRequests.detail"), Ok(detail()));
    review.answer(
        then_of(&first, "POST /api/pull-requests/diff"),
        Err("late".into()),
    );
    assert_eq!(review.detail(), &json!({}));
    assert_eq!(review.code_status(), "loading");
}

#[test]
fn the_conversation_and_review_threads_come_from_the_activity() {
    let (mut review, first) = loaded();
    review.answer(
        then_of(&first, "pullRequests.activity"),
        Ok(json!({
            "comments": [{"id": "c1", "kind": "review", "author": {"login": "bob"}, "body": "LGTM", "reviewState": "approved"}],
            "reviewThreads": [{"id": "t1", "path": "x.rs", "line": 3, "isResolved": true, "comments": [{"author": {"login": "ada"}, "body": "?"}]}],
        })),
    );
    assert_eq!(
        review.conversation(),
        [
            json!({"id": "c1", "kind": "review", "author": "bob", "body": "LGTM", "createdAt": "", "reviewState": "approved", "path": ""})
        ]
    );
    assert_eq!(
        review.review_threads(),
        [
            json!({"id": "t1", "path": "x.rs", "line": 3, "resolved": true, "outdated": false, "comments": [{"author": "ada", "body": "?"}]})
        ]
    );
}

#[test]
fn a_file_marked_viewed_folds_at_once_and_unfolds_if_the_host_refuses() {
    let (mut review, first) = loaded();
    review.answer(
        then_of(&first, "pullRequests.filesViewed"),
        Ok(json!({"files": [{"path": "a.rs", "state": "viewed"}, {"path": "b.rs", "state": "unviewed"}]})),
    );
    assert_eq!(review.take_effects(), vec![Effect::FoldViewed]);
    let paths: Vec<String> = ["a.rs", "b.rs", "c.rs"].map(String::from).into();
    assert_eq!(review.viewed_of(&paths), ["a.rs"]);

    review.set_viewed("a.rs", true);
    assert!(review.take_effects().is_empty(), "already viewed");
    review.set_viewed("b.rs", true);
    let effects = review.take_effects();
    assert_eq!(
        effects[0],
        Effect::Expand {
            path: "b.rs".into(),
            expanded: false
        }
    );
    let Effect::Call {
        method: "pullRequests.setFilesViewed",
        payload,
        then,
        ..
    } = &effects[1]
    else {
        panic!("{effects:?}");
    };
    assert_eq!(payload["files"], json!([{"path": "b.rs", "viewed": true}]));
    assert!(review.is_viewed("b.rs"));
    review.answer(then.clone(), Err("forbidden".into()));
    assert!(!review.is_viewed("b.rs"));
    assert_eq!(
        review.take_effects(),
        vec![
            Effect::Expand {
                path: "b.rs".into(),
                expanded: true
            },
            Effect::Notify {
                kind: "error",
                title: "Could not mark the file viewed".into(),
                description: "forbidden".into(),
            },
        ]
    );
}

fn stack() -> Json {
    json!({
        "number": 7,
        "base": "main",
        "layers": [
            {"number": 5, "title": "One", "state": "merged", "headSha": "a"},
            {"number": 6, "title": "Two", "state": "open", "headSha": "b"},
            {"number": 7, "title": "Three", "state": "open", "headSha": "c"},
            {"number": 8, "title": "Four", "state": "open", "headSha": "d"},
        ],
    })
}

fn stacked() -> Review {
    let (mut review, first) = loaded();
    review.answer(then_of(&first, "pullRequests.detail"), Ok(detail()));
    review.answer(then_of(&first, "pullRequests.stack"), Ok(stack()));
    review.take_effects();
    review
}

#[test]
fn a_stack_shows_where_this_layer_is_and_what_can_be_done() {
    let review = stacked();
    let shown = review.stack();
    assert_eq!(shown["position"], 3);
    assert_eq!(shown["size"], 4);
    assert_eq!(shown["mergeCount"], 2);
    assert_eq!(shown["canMerge"], true);
    assert_eq!(shown["canRebase"], true);
    assert_eq!(shown["layers"][2]["current"], true);
    assert_eq!(shown["notice"], "");
}

#[test]
fn a_stack_that_could_not_be_read_again_is_stale() {
    let mut review = stacked();
    review.retry_stack();
    let asked = asked(&mut review);
    review.answer(then_of(&asked, "pullRequests.stack"), Err("timeout".into()));
    let shown = review.stack();
    assert_eq!(shown["stale"], true);
    assert_eq!(shown["canMerge"], false);
    assert_eq!(
        shown["notice"],
        "Stack data may be stale. We couldn’t refresh it."
    );
}

#[test]
fn merging_a_stack_asks_first_then_sends_the_heads_seen() {
    let mut review = stacked();
    assert!(review.request_stack_merge(""));
    let confirmation = review.stack_confirmation().clone();
    assert_eq!(confirmation["title"], "Merge 2 pull requests?");
    assert_eq!(
        confirmation["description"],
        "Merge #7 and its unmerged layers below into main using squash. GitHub checks their rules before merging or queueing them and rebases the remaining stack after merging."
    );
    review.cancel_stack();
    assert_eq!(review.stack_confirmation(), &json!({}));
    assert!(review.request_stack_merge("rebase"));
    review.confirm_stack();
    assert!(review.busy());
    let asked = asked(&mut review);
    let [(method, payload, then)] = asked.as_slice() else {
        panic!("{asked:?}");
    };
    assert_eq!(method, "pullRequests.runAction");
    assert_eq!(
        *payload,
        json!({
            "projectId": "p1", "host": "github.com", "repository": "acme/app", "number": 7,
            "stackNumber": 7,
            "expectedStackHeads": [{"number": 6, "headSha": "b"}, {"number": 7, "headSha": "c"}],
            "action": "merge",
            "mergeMethod": "rebase",
        })
    );
    review.answer(then.clone(), Ok(json!({})));
    assert!(!review.busy());
    let effects = review.take_effects();
    assert_eq!(
        effects[0],
        Effect::Notify {
            kind: "success",
            title: "Stack merge request completed".into(),
            description: "GitHub merged the stack or added it to its merge queue.".into(),
        }
    );
    assert!(
        effects.iter().any(|e| matches!(
            e,
            Effect::Call {
                method: "pullRequests.detail",
                ..
            }
        )),
        "read again"
    );
}

#[test]
fn rebasing_a_stack_updates_its_top_onto_the_base() {
    let mut review = stacked();
    assert!(review.request_stack_rebase());
    assert_eq!(
        review.stack_confirmation()["title"],
        "Rebase 3 pull requests?"
    );
    review.confirm_stack();
    let asked = asked(&mut review);
    let payload = &asked[0].1;
    assert_eq!(payload["number"], 8);
    assert_eq!(payload["action"], "update-branch");
    assert_eq!(payload["updateMethod"], "rebase");
    assert_eq!(payload["expectedStackHeads"].as_array().unwrap().len(), 3);
}

#[test]
fn a_merge_takes_an_allowed_method_and_says_so() {
    let mut review = ready();
    assert!(!review.merge("merge"));
    assert_eq!(
        review.problem(),
        "This repository does not allow that merge method."
    );
    assert!(review.merge(""));
    assert_eq!(review.problem(), "");
    let asked = asked(&mut review);
    assert_eq!(asked[0].1["mergeMethod"], "squash");
    review.answer(asked[0].2.clone(), Ok(json!({})));
    assert_eq!(
        review.take_effects()[0],
        Effect::Notify {
            kind: "success",
            title: "Merged".into(),
            description: "#7".into()
        }
    );
}

#[test]
fn a_change_refused_is_the_problem_and_a_toast() {
    let mut review = ready();
    assert!(review.comment("Nice"));
    let asked = asked(&mut review);
    assert_eq!(asked[0].0, "pullRequests.comment");
    assert_eq!(asked[0].1["body"], "Nice");
    let Then::Change { done, .. } = &asked[0].2 else {
        panic!("a change");
    };
    assert_eq!(*done, Done::Nothing);
    review.answer(asked[0].2.clone(), Err("locked".into()));
    assert_eq!(review.problem(), "locked");
    assert_eq!(
        review.take_effects(),
        vec![Effect::Notify {
            kind: "error",
            title: "Could not comment".into(),
            description: "locked".into()
        }]
    );
}

#[test]
fn what_cannot_be_sent_says_why() {
    let mut review = ready();
    assert!(!review.comment("  "));
    assert_eq!(review.problem(), "A comment cannot be empty.");
    assert!(!review.submit_review("comment", ""));
    assert_eq!(
        review.problem(),
        "A review needs a summary or at least one comment."
    );
    assert!(!review.submit_review("shrug", "x"));
    assert!(review.submit_review("approve", ""));
    let asked = asked(&mut review);
    assert_eq!(asked[0].1["verdict"], "approve");
    assert_eq!(asked[0].1["comments"], json!([]));
    review.answer(asked[0].2.clone(), Ok(json!({})));
    assert_eq!(
        review.take_effects()[0],
        Effect::Notify {
            kind: "success",
            title: "Approved".into(),
            description: "#7".into()
        }
    );

    review.set_online(false);
    review.set_thread_resolved("t1", true);
    assert_eq!(review.problem(), "The environment is offline.");
    assert!(asked_nothing(&mut review));
}

fn asked_nothing(review: &mut Review) -> bool {
    asked(review).is_empty()
}

#[test]
fn copy_and_open_take_the_number_and_the_page() {
    let mut review = ready();
    review.copy_number();
    review.open_on_host();
    assert_eq!(
        review.take_effects(),
        vec![
            Effect::CopyNumber("#7".into()),
            Effect::Open("https://github.com/acme/app/pull/7".into()),
        ]
    );
    review.clear();
    review.copy_number();
    assert_eq!(review.take_effects(), vec![Effect::Clear]);
}
