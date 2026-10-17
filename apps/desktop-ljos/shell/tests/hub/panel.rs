//! `panel`: the right panel beside a thread, each thread's tabs, its width,
//! the details column, kept across a restart (RightPanelController.cpp,
//! PanelSteps.cpp, features/layout/layout.feature).

use std::cell::RefCell;
use std::path::Path;
use std::rc::Rc;

use hal_c2_shell::Launch;
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::commands::Commands;
use hal_c2_shell::controllers::panel::{PanelObject, RightPanel};
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::terminals::Terminals;
use hal_c2_shell::controllers::threads;
use hal_c2_shell::json::Json;
use hal_c2_shell::thread_view::agents::AgentsModel;
use hal_c2_shell::thread_view::pull_request_review::PullRequestReview;
use hal_c2_shell::thread_view::workspace_files::WorkspaceFiles;
use ljos::prelude::ObjectId;
use serde_json::json;

use crate::Hub;
use crate::page::last;

/// The MC's `shell` frame: project `p1` and `threads`, each row as given
/// (an id, and what else it carries), its environment's `capabilities`.
fn shell(hub: &Hub, threads: &[Json], capabilities: Json) {
    shell_with(
        hub,
        json!({"id": "p1", "title": "P", "workspaceRoot": "/work/p"}),
        threads,
        capabilities,
    );
}

/// The `shell` frame, project p1 being `project`.
fn shell_with(hub: &Hub, project: Json, threads: &[Json], capabilities: Json) {
    let mut rows = vec![json!(["a", "p1", "project", project])];
    for row in threads {
        let id = row["id"].as_str().unwrap();
        let mut row = row.clone();
        row["projectId"] = json!("p1");
        if row.get("title").is_none() {
            row["title"] = json!(id.to_uppercase());
        }
        rows.push(json!(["a", id, "thread", row]));
    }
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell", "mcs": [{"mc": "a", "online": true, "epoch": "e", "rev": 1,
            "environment": {"environmentId": "env-1", "label": "Here",
                "capabilities": capabilities}}], "rows": rows}),
    );
}

fn rows(ids: &[&str]) -> Vec<Json> {
    ids.iter().map(|id| json!({"id": id})).collect()
}

fn hub_with(launch: Launch, threads: &[Json]) -> Hub {
    let hub = Hub::with(Launch {
        mc_origin: Some("http://127.0.0.1:1".into()),
        ..launch
    });
    hub.mc.set_ready(&hub.engine, true);
    shell(&hub, threads, json!({}));
    hub
}

fn hub(ids: &[&str]) -> Hub {
    hub_with(Launch::default(), &rows(ids))
}

/// A hub whose device settings can be changed: they are kept in a folder of
/// their own, removed with it.
fn device_hub(ids: &[&str]) -> (Hub, tempfile::TempDir) {
    let dir = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).unwrap();
    let launch = Launch {
        config_dir: Some(dir.path().to_owned()),
        ..Launch::default()
    };
    (hub_with(launch, &rows(ids)), dir)
}

fn open(hub: &Hub, thread: &str) {
    hub.dispatch("thread.open", json!({"key": format!("env-1:{thread}")}));
}

fn panel(hub: &Hub) -> Json {
    hub.published("panel")
}

fn titles(hub: &Hub) -> Vec<String> {
    panel(hub)["tabs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["title"].as_str().unwrap().to_owned())
        .collect()
}

fn run(hub: &Hub, command: &str) {
    assert!(
        Commands::of(&hub.engine).run(&hub.engine, command),
        "{command} runs"
    );
}

fn diffs_asked(hub: &Hub) -> usize {
    hub.mc
        .methods()
        .iter()
        .filter(|m| *m == "orchestration.getTurnDiff")
        .count()
}

/// The thread's stream sends its checkpoints (id, turn, files changed).
fn checkpoints(hub: &Hub, thread: &str, checkpoints: &[(&str, i32, usize)]) {
    let (id, _) = hub
        .mc
        .subscriptions()
        .into_iter()
        .find(|(_, shape)| shape["type"] == "stream" && shape["stream"] == thread)
        .expect("the thread is followed");
    let rows: Vec<Json> = checkpoints
        .iter()
        .map(|(cp, turn, files)| {
            let files: Vec<Json> = (0..*files)
                .map(|n| json!({"path": format!("f{n}.ts"), "additions": 1, "deletions": 0}))
                .collect();
            json!(["checkpoint", cp, {"id": cp, "appRunOrdinal": turn, "status": "ready",
                "scopeId": "s", "files": files}])
        })
        .collect();
    let offset = rows.len();
    hub.mc.frame_to(
        &hub.engine,
        id,
        json!({"t": "snapshot", "part": 0, "rows": rows, "done": true, "offset": offset,
            "handle": "log-1"}),
    );
    hub.mc.frame_to(
        &hub.engine,
        id,
        json!({"t": "live", "offset": offset, "handle": "log-1"}),
    );
}

#[test]
fn off_a_thread_the_panel_is_null_and_on_one_it_toggles() {
    let hub = hub(&["t1"]);
    assert_eq!(panel(&hub), Json::Null);
    open(&hub, "t1");
    assert_eq!(panel(&hub)["threadKey"], "env-1:t1");
    assert_eq!(panel(&hub)["isOpen"], false);
    assert_eq!(panel(&hub)["width"], 540);
    hub.dispatch("rightPanel.toggle", json!({}));
    // An empty panel opens on the Diff.
    assert_eq!(panel(&hub)["isOpen"], true);
    assert_eq!(panel(&hub)["activeId"], "diff");
    assert_eq!(titles(&hub), ["Diff"]);
    hub.dispatch("rightPanel.toggle", json!({}));
    assert_eq!(panel(&hub)["isOpen"], false);
    assert_eq!(titles(&hub), ["Diff"]);
}

#[test]
fn tabs_are_added_switched_and_closed() {
    let hub = hub(&["t1"]);
    open(&hub, "t1");
    hub.dispatch("rightPanel.add", json!({"kind": "diff"}));
    hub.dispatch("rightPanel.add", json!({"kind": "files"}));
    assert_eq!(titles(&hub), ["Diff", "Files"]);
    assert_eq!(panel(&hub)["activeId"], "files");
    hub.dispatch("rightPanel.activate", json!({"id": "diff"}));
    assert_eq!(panel(&hub)["activeId"], "diff");
    hub.dispatch("rightPanel.close", json!({"id": "files"}));
    assert_eq!(titles(&hub), ["Diff"]);
    assert_eq!(panel(&hub)["activeId"], "diff");
    // Unknown kinds and pull requests that name none are not shown.
    hub.dispatch("rightPanel.activate", json!({"id": "nonsense"}));
    hub.dispatch(
        "rightPanel.activate",
        json!({"id": "pull-request:github.com/o/r#x"}),
    );
    assert_eq!(titles(&hub), ["Diff"]);
    // A project's pull request is reviewed in a tab of its own.
    hub.dispatch(
        "rightPanel.reviewProject",
        json!({"key": "github.com/o/r#12"}),
    );
    assert_eq!(titles(&hub), ["Diff", "PR #12"]);
    assert_eq!(panel(&hub)["tabs"][1]["kind"], "pull-request");
    // Closing the last tab closes the panel.
    hub.dispatch("rightPanel.close", json!({"id": "diff"}));
    hub.dispatch("rightPanel.close", json!({}));
    assert_eq!(titles(&hub), Vec::<String>::new());
    assert_eq!(panel(&hub)["isOpen"], false);
}

#[test]
fn the_add_menu_says_what_can_be_added() {
    let hub = hub(&["t1"]);
    open(&hub, "t1");
    let can = panel(&hub)["canAdd"].clone();
    assert_eq!(can["diff"], true);
    assert_eq!(can["files"], true, "the project has a folder");
    assert_eq!(can["pullRequests"], false);
    assert_eq!(
        panel(&hub)["addReasons"]["pullRequest"],
        "This thread's branch has no pull request yet."
    );
    assert_eq!(panel(&hub)["addReasons"]["files"], "");
    hub.dispatch("rightPanel.add", json!({"kind": "agents"}));
    assert_eq!(panel(&hub)["isOpen"], true);
    assert_eq!(panel(&hub)["activeId"], "agents");
    assert_eq!(panel(&hub)["tabs"][0]["kind"], "agents");
    // A browser tab is a new tab of the Previews.
    hub.dispatch("rightPanel.add", json!({"kind": "browser"}));
    assert_eq!(panel(&hub)["activeId"], "previews");
}

#[test]
fn the_panel_is_resized_and_reset() {
    let hub = hub(&["t1"]);
    open(&hub, "t1");
    hub.dispatch("rightPanel.resize", json!({"width": 612}));
    assert_eq!(panel(&hub)["width"], 612);
    hub.dispatch("rightPanel.resize", json!({"width": 100}));
    assert_eq!(panel(&hub)["width"], 360);
    hub.dispatch("rightPanel.resize", json!({}));
    assert_eq!(panel(&hub)["width"], 540);
}

#[test]
fn the_panel_fills_the_window_while_open() {
    let hub = hub(&["t1"]);
    open(&hub, "t1");
    // Closed, it stays beside the thread.
    run(&hub, "rightPanel.toggleMaximized");
    assert_eq!(panel(&hub)["maximized"], false);
    hub.dispatch("rightPanel.toggle", json!({}));
    run(&hub, "rightPanel.toggleMaximized");
    assert_eq!(panel(&hub)["maximized"], true);
    hub.dispatch("rightPanel.toggleMaximized", json!({}));
    assert_eq!(panel(&hub)["maximized"], false);
    // Closing it brings it back beside the thread.
    hub.dispatch("rightPanel.toggleMaximized", json!({}));
    hub.dispatch("rightPanel.toggle", json!({}));
    hub.dispatch("rightPanel.toggle", json!({}));
    assert_eq!(panel(&hub)["isOpen"], true);
    assert_eq!(panel(&hub)["maximized"], false);
}

#[test]
fn the_diff_and_previews_commands_toggle_their_tabs() {
    let hub = hub(&["t1"]);
    open(&hub, "t1");
    run(&hub, "diff.toggle");
    assert_eq!(panel(&hub)["activeId"], "diff");
    assert_eq!(panel(&hub)["isOpen"], true);
    run(&hub, "preview.toggle");
    assert_eq!(panel(&hub)["activeId"], "previews");
    run(&hub, "preview.toggle");
    assert_eq!(panel(&hub)["isOpen"], false);
    // mod+w closes the active tab.
    run(&hub, "diff.toggle");
    run(&hub, "rightPanel.close");
    assert_eq!(titles(&hub), ["Previews"]);
}

#[test]
fn the_details_column_shows_where_the_thread_runs_and_its_relations() {
    let parent = json!({"id": "parent", "title": "Planning"});
    let thread = json!({"id": "t1", "branch": "main",
        "lineage": {"parentThreadId": "parent", "relationshipToParent": "fork"}});
    let child = json!({"id": "c1", "title": "Helper", "subagent": true,
        "lineage": {"parentThreadId": "t1", "relationshipToParent": "subagent"}});
    let hub = hub_with(Launch::default(), &[parent, thread, child]);
    open(&hub, "t1");
    assert_eq!(panel(&hub)["details"], Json::Null);
    run(&hub, "threadPanel.toggle");
    let details = panel(&hub)["details"].clone();
    assert_eq!(panel(&hub)["detailsOpen"], true);
    assert_eq!(details["environment"], "Here");
    assert_eq!(details["online"], true);
    assert_eq!(details["project"], "P");
    assert_eq!(details["folder"], "/work/p");
    assert_eq!(details["checkout"], "Local");
    assert_eq!(details["branch"], "main");
    assert_eq!(
        details["relations"],
        json!([
            {"threadKey": "env-1:parent", "title": "Planning", "relation": "Forked from"},
            {"threadKey": "env-1:c1", "title": "Helper", "relation": "Subagent",
                "status": "finished"},
        ])
    );
    hub.dispatch(
        "rightPanel.openThread",
        json!({"threadKey": "env-1:parent"}),
    );
    assert_eq!(threads::active(&hub.engine), "env-1:parent");
    assert_eq!(panel(&hub)["threadKey"], "env-1:parent");
    assert_eq!(panel(&hub)["detailsOpen"], false, "each thread has its own");
    hub.dispatch("threadPanel.toggle", json!({}));
    hub.dispatch("threadPanel.toggle", json!({}));
    assert_eq!(panel(&hub)["details"], Json::Null);
}

#[test]
fn each_thread_keeps_its_own_panel() {
    let hub = hub(&["t1", "t2"]);
    open(&hub, "t1");
    hub.dispatch("rightPanel.add", json!({"kind": "files"}));
    open(&hub, "t2");
    assert_eq!(panel(&hub)["threadKey"], "env-1:t2");
    assert_eq!(panel(&hub)["isOpen"], false);
    assert_eq!(titles(&hub), Vec::<String>::new());
    open(&hub, "t1");
    assert_eq!(panel(&hub)["isOpen"], true);
    assert_eq!(titles(&hub), ["Files"]);
    // Arriving at a thread snaps; opening within it slides (none here: no
    // duration is set).
    assert_eq!(panel(&hub)["transitionMs"], 0);
}

#[test]
fn opening_within_a_thread_slides_for_the_set_duration() {
    let (hub, _dir) = device_hub(&["t1"]);
    Settings::of(&hub.engine).set(&hub.engine, "panelAnimationDurationMs", json!(900));
    open(&hub, "t1");
    hub.dispatch("rightPanel.toggle", json!({}));
    assert_eq!(panel(&hub)["transitionMs"], 400, "at most 400");
    Settings::of(&hub.engine).set(&hub.engine, "reduceMotion", json!(true));
    hub.dispatch("rightPanel.toggle", json!({}));
    assert_eq!(panel(&hub)["transitionMs"], 0);
}

#[test]
fn a_closed_panel_does_not_ask_for_the_diff_and_opening_it_asks_once() {
    let hub = hub(&["t1"]);
    open(&hub, "t1");
    checkpoints(&hub, "t1", &[("cp-1", 1, 1)]);
    assert_eq!(diffs_asked(&hub), 0);
    hub.dispatch("rightPanel.toggle", json!({}));
    assert_eq!(diffs_asked(&hub), 1);
    hub.mc.answer(
        &hub.engine,
        "orchestration.getTurnDiff",
        Ok(json!({"diff": "diff --git a/f0.ts b/f0.ts\n--- a/f0.ts\n+++ b/f0.ts\n@@ -1 +1 @@\n-a\n+b\n"})),
    );
    // A visit to settings: the panel steps aside and comes back as it was,
    // its diff not asked for again.
    let before = panel(&hub);
    hub.dispatch("settings.open", json!({}));
    assert_eq!(panel(&hub), Json::Null);
    hub.dispatch("settings.back", json!({}));
    assert_eq!(panel(&hub), before);
    assert_eq!(diffs_asked(&hub), 1);
    // Closed, a new turn is not diffed until it is opened.
    hub.dispatch("rightPanel.toggle", json!({}));
    checkpoints(&hub, "t1", &[("cp-1", 1, 1), ("cp-2", 2, 1)]);
    assert_eq!(diffs_asked(&hub), 1);
    hub.dispatch("rightPanel.toggle", json!({}));
    assert_eq!(diffs_asked(&hub), 2);
}

#[test]
fn a_large_turn_opens_the_diff_when_proactive_panels_are_on() {
    let (hub, _dir) = device_hub(&["t1", "t2"]);
    open(&hub, "t1");
    checkpoints(&hub, "t1", &[("cp-1", 1, 3)]);
    assert_eq!(panel(&hub)["isOpen"], false, "proactive panels are off");
    Settings::of(&hub.engine).set(&hub.engine, "proactivePanelsEnabled", json!(true));
    assert_eq!(panel(&hub)["isOpen"], true);
    assert_eq!(panel(&hub)["activeId"], "diff");
    // Once per turn: closed, it stays closed.
    hub.dispatch("rightPanel.toggle", json!({}));
    open(&hub, "t2");
    open(&hub, "t1");
    assert_eq!(panel(&hub)["isOpen"], false);
    // A small turn does not open it.
    open(&hub, "t2");
    checkpoints(&hub, "t2", &[("cp-9", 1, 1)]);
    assert_eq!(panel(&hub)["isOpen"], false);
}

#[test]
fn a_link_menu_opens_or_copies_a_path_or_an_address() {
    let hub = hub(&["t1"]);
    open(&hub, "t1");
    let copied = Rc::new(RefCell::new(Vec::<String>::new()));
    let sink = copied.clone();
    Bridge::of(&hub.engine).set_clipboard_writer(&hub.engine, move |t| {
        sink.borrow_mut().push(t.to_owned());
        true
    });
    let choose = |url: &str, id: &str| {
        hub.dispatch("link.menu", json!({"url": url, "x": 4, "y": 8}));
        let menu = hub.published("menu");
        let labels: Vec<&str> = menu["items"]
            .as_array()
            .unwrap()
            .iter()
            .map(|i| i["label"].as_str().unwrap())
            .collect();
        let labels = labels.join("|");
        hub.dispatch(
            "menu.select",
            json!({"requestId": menu["requestId"], "id": id}),
        );
        labels
    };
    assert_eq!(choose("src/a%20b.ts#L3", "copy"), "Open file|Copy path");
    assert_eq!(
        choose("https://example.com/x", "copy"),
        "Open link|Copy link"
    );
    assert_eq!(*copied.borrow(), ["src/a b.ts", "https://example.com/x"]);
    choose("src/cart.ts:12", "open");
    assert_eq!(panel(&hub)["activeId"], "files");
    assert_eq!(panel(&hub)["isOpen"], true);
}

#[test]
fn the_pull_request_commands_follow_the_environment() {
    let hub = hub(&["t1"]);
    let row = |command: &str| {
        Commands::of(&hub.engine)
            .rows()
            .into_iter()
            .find(|r| r.command == command)
            .map(|r| (r.listed, r.enabled))
            .unwrap()
    };
    open(&hub, "t1");
    assert_eq!(row("thread.linkPullRequest"), (false, false));
    shell(&hub, &rows(&["t1"]), json!({"threadPullRequests": true}));
    assert_eq!(row("thread.linkPullRequest"), (true, true));
    assert_eq!(row("thread.showPullRequests"), (true, false), "none linked");
}

#[test]
fn the_tab_models_are_the_panel_singletons() {
    let hub = hub(&["t1"]);
    let obj = hub.engine.singleton::<PanelObject>().unwrap();
    let diff = hub.engine.read_by_name(obj, "diff");
    assert!(matches!(diff, ljos::prelude::Value::Object(_)));
    let previews = hub.engine.read_by_name(obj, "previews");
    assert!(matches!(previews, ljos::prelude::Value::Object(_)));
    let files = hub.engine.read_by_name(obj, "files");
    assert!(matches!(files, ljos::prelude::Value::Object(_)));
    let device = hub.engine.read_by_name(obj, "device");
    assert!(matches!(device, ljos::prelude::Value::Object(_)));
    let agents = hub.engine.read_by_name(obj, "agents");
    assert!(matches!(agents, ljos::prelude::Value::Object(_)));
    let pull_requests = hub.engine.read_by_name(obj, "pullRequests");
    assert!(matches!(pull_requests, ljos::prelude::Value::Object(_)));
    let review = hub.engine.read_by_name(obj, "review");
    assert!(matches!(review, ljos::prelude::Value::Object(_)));
}

/// The Panel singleton's model `name`.
fn model(hub: &Hub, name: &str) -> ObjectId {
    let obj = hub.engine.singleton::<PanelObject>().unwrap();
    match hub.engine.read_by_name(obj, name) {
        ljos::prelude::Value::Object(model) => model,
        other => panic!("the panel's {name} is {other:?}"),
    }
}

/// A pull request of acme/shop linked to a thread, in `state` (none: not
/// synced yet).
fn linked(number: i64, state: Option<&str>) -> Json {
    let mut link = json!({"host": "github.com", "repository": "acme/shop", "number": number,
        "url": format!("https://github.com/acme/shop/pull/{number}"), "source": "manual"});
    if let Some(state) = state {
        link["snapshot"] = json!({"state": state, "title": format!("PR {number}")});
    }
    link
}

/// Thread t1, linked to `links`, on an environment that keeps them.
fn linked_hub(links: Vec<Json>) -> Hub {
    let hub = hub(&["t1"]);
    shell_with(
        &hub,
        json!({"id": "p1", "title": "P", "workspaceRoot": "/work/p",
            "repositoryIdentity": {"canonicalKey": "github.com/acme/shop"}}),
        &[json!({"id": "t1", "pullRequests": links})],
        json!({"threadPullRequests": true}),
    );
    open(&hub, "t1");
    hub
}

fn command_row(hub: &Hub, command: &str) -> (bool, bool) {
    Commands::of(&hub.engine)
        .rows()
        .into_iter()
        .find(|r| r.command == command)
        .map(|r| (r.listed, r.enabled))
        .unwrap()
}

fn reviewing(hub: &Hub) -> bool {
    PullRequestReview::read(&hub.engine, model(hub, "review"), |r| r.active()).unwrap()
}

#[test]
fn linked_pull_requests_fill_the_add_menu_and_the_palette() {
    let hub = linked_hub(vec![linked(41, Some("merged")), linked(42, Some("open"))]);
    assert_eq!(panel(&hub)["canAdd"]["pullRequests"], true);
    assert_eq!(panel(&hub)["canAdd"]["pullRequest"], true);
    assert_eq!(command_row(&hub, "thread.showPullRequests"), (true, true));
    run(&hub, "thread.showPullRequests");
    assert_eq!(panel(&hub)["activeId"], "pull-requests");
    // Unlinked everywhere, the palette and the add menu follow.
    shell(
        &hub,
        &[json!({"id": "t1", "pullRequests": []})],
        json!({"threadPullRequests": true}),
    );
    assert_eq!(command_row(&hub, "thread.showPullRequests"), (true, false));
    assert_eq!(panel(&hub)["canAdd"]["pullRequests"], false);
}

#[test]
fn adding_a_review_reviews_the_first_open_linked_pull_request() {
    let hub = linked_hub(vec![linked(41, Some("merged")), linked(42, Some("open"))]);
    assert!(!reviewing(&hub));
    hub.dispatch("rightPanel.add", json!({"kind": "pull-request"}));
    assert_eq!(
        panel(&hub)["activeId"],
        "pull-request:github.com/acme/shop#42"
    );
    assert_eq!(titles(&hub), ["PR #42"]);
    assert!(reviewing(&hub));
    // It reads that pull request, and its code over HTTP.
    let detail = last(&hub, "env-1", "pullRequests.detail");
    assert_eq!(
        detail,
        json!({"projectId": "p1", "host": "github.com", "repository": "acme/shop",
            "number": 42})
    );
    assert!(
        hub.mc
            .pending_on("", "POST /api/pull-requests/diff")
            .is_some()
    );
    // Only a linked one is reviewed.
    hub.dispatch(
        "rightPanel.review",
        json!({"key": "github.com/acme/shop#7"}),
    );
    assert_eq!(
        panel(&hub)["activeId"],
        "pull-request:github.com/acme/shop#42"
    );
    hub.dispatch(
        "rightPanel.review",
        json!({"key": "github.com/acme/shop#41"}),
    );
    assert_eq!(
        panel(&hub)["activeId"],
        "pull-request:github.com/acme/shop#41"
    );
    assert_eq!(
        last(&hub, "env-1", "pullRequests.detail")["number"],
        41,
        "the review follows the tab"
    );
    // Closed, the review is not in view.
    hub.dispatch("rightPanel.toggle", json!({}));
    assert!(!reviewing(&hub));
}

#[test]
fn the_pull_request_number_is_copied_while_a_review_shows() {
    let hub = linked_hub(vec![linked(42, Some("open"))]);
    let copied = Rc::new(RefCell::new(Vec::<String>::new()));
    let sink = copied.clone();
    Bridge::of(&hub.engine).set_clipboard_writer(&hub.engine, move |t| {
        sink.borrow_mut().push(t.to_owned());
        true
    });
    run(&hub, "pullRequest.copyNumber");
    assert!(copied.borrow().is_empty(), "no review shows");
    hub.dispatch("rightPanel.add", json!({"kind": "pull-request"}));
    run(&hub, "pullRequest.copyNumber");
    assert_eq!(*copied.borrow(), ["#42"]);
}

#[test]
fn a_link_naming_a_pull_request_links_it_to_the_thread() {
    let hub = linked_hub(vec![]);
    let choose = |url: &str, id: Option<&str>| {
        hub.dispatch("link.menu", json!({"url": url, "x": 4, "y": 8}));
        let menu = hub.published("menu");
        let ids: Vec<String> = menu["items"]
            .as_array()
            .unwrap()
            .iter()
            .map(|i| i["id"].as_str().unwrap().to_owned())
            .collect();
        hub.dispatch(
            "menu.select",
            json!({"requestId": menu["requestId"], "id": id.unwrap_or("none")}),
        );
        ids
    };
    assert_eq!(choose("https://example.com/x", None), ["open", "copy"]);
    assert_eq!(
        choose(
            "https://github.com/acme/shop/pull/43",
            Some("link-pull-request")
        ),
        ["open", "copy", "link-pull-request"]
    );
    assert_eq!(panel(&hub)["activeId"], "pull-requests");
    let command = last(&hub, "env-1", "orchestration.dispatchCommand");
    assert_eq!(command["type"], "thread.pull-request.link");
    assert_eq!(command["threadId"], "t1");
    assert_eq!(command["number"], 43);
    // Where the environment links none, it is not offered.
    let other = self::hub(&["t1"]);
    open(&other, "t1");
    other.dispatch(
        "link.menu",
        json!({"url": "https://github.com/acme/shop/pull/43", "x": 0, "y": 0}),
    );
    assert_eq!(
        other.published("menu")["items"].as_array().unwrap().len(),
        2
    );
}

#[test]
fn a_mentioned_pull_request_and_the_palette_link_from_the_tab() {
    let hub = linked_hub(vec![]);
    hub.dispatch(
        "rightPanel.linkPullRequest",
        json!({"url": "https://github.com/acme/shop/pull/44"}),
    );
    assert_eq!(panel(&hub)["activeId"], "pull-requests");
    assert_eq!(
        last(&hub, "env-1", "orchestration.dispatchCommand")["number"],
        44
    );
    let tab = model(&hub, "pullRequests");
    assert_eq!(
        hub.engine.read_by_name(tab, "linkOpen"),
        ljos::prelude::Value::Bool(false)
    );
    run(&hub, "thread.linkPullRequest");
    assert_eq!(
        hub.engine.read_by_name(tab, "linkOpen"),
        ljos::prelude::Value::Bool(true)
    );
}

#[test]
fn the_projects_open_pull_requests_are_read_once_unless_asked_again() {
    let hub = linked_hub(vec![]);
    let tab = model(&hub, "pullRequests");
    let asked = || crate::page::count(&hub, "pullRequests.list");
    crate::common::call(&hub.engine, tab, "loadProject", &[]);
    crate::common::call(&hub.engine, tab, "loadProject", &[]);
    assert_eq!(asked(), 1);
    assert_eq!(last(&hub, "env-1", "pullRequests.list")["projectId"], "p1");
    crate::common::call(
        &hub.engine,
        tab,
        "loadProject",
        &[ljos::prelude::Value::Bool(true)],
    );
    assert_eq!(asked(), 2);
}

/// Whether the panel's Agents tab is told it shows.
fn agents_shown(hub: &Hub) -> bool {
    let obj = hub.engine.singleton::<PanelObject>().unwrap();
    let ljos::prelude::Value::Object(agents) = hub.engine.read_by_name(obj, "agents") else {
        panic!("the panel has no Agents tab");
    };
    AgentsModel::read_core(&hub.engine, agents, |a| a.active()).unwrap()
}

#[test]
fn the_agents_tab_is_told_while_it_shows() {
    let hub = hub(&["t1"]);
    open(&hub, "t1");
    assert!(!agents_shown(&hub));
    hub.dispatch("rightPanel.add", json!({"kind": "agents"}));
    assert_eq!(panel(&hub)["activeId"], "agents");
    assert!(agents_shown(&hub));
    hub.dispatch("rightPanel.add", json!({"kind": "diff"}));
    assert!(!agents_shown(&hub));
    hub.dispatch("rightPanel.activate", json!({"id": "agents"}));
    assert!(agents_shown(&hub));
    hub.dispatch("rightPanel.toggle", json!({}));
    assert!(!agents_shown(&hub));
}

fn terminal_ids(hub: &Hub) -> Vec<String> {
    hub.with_controller::<Terminals, _>(|t, _| t.terminal_ids())
}

#[test]
fn a_terminal_tab_is_a_terminal_of_its_own_closed_with_it_once_the_user_agrees() {
    let hub = crate::workspace::on_thread("main", None);
    assert_eq!(panel(&hub)["canAdd"]["terminal"], true);
    hub.dispatch("rightPanel.add", json!({"kind": "terminal"}));
    let tab = panel(&hub)["activeId"].as_str().unwrap().to_owned();
    assert!(tab.starts_with("terminal:"), "{tab}");
    assert_eq!(titles(&hub), ["Terminal"]);
    assert_eq!(terminal_ids(&hub), ["term-1"]);
    // Another is a tab of its own.
    hub.dispatch("rightPanel.add", json!({"kind": "terminal"}));
    assert_eq!(titles(&hub), ["Terminal", "Terminal"]);
    assert_eq!(terminal_ids(&hub), ["term-1", "term-2"]);

    // Closing asks first: no keeps both.
    hub.dispatch("rightPanel.close", json!({"id": tab}));
    let question = hub.published("confirmation");
    assert_eq!(question["title"], "Close terminal \"Terminal 1\"?");
    hub.dispatch(
        "confirmation.answer",
        json!({"requestId": question["requestId"], "accepted": false}),
    );
    assert_eq!(titles(&hub).len(), 2);
    assert_eq!(terminal_ids(&hub), ["term-1", "term-2"]);

    hub.dispatch("rightPanel.close", json!({"id": tab}));
    let question = hub.published("confirmation");
    hub.dispatch(
        "confirmation.answer",
        json!({"requestId": question["requestId"], "accepted": true}),
    );
    assert_eq!(titles(&hub), ["Terminal"]);
    assert_eq!(terminal_ids(&hub), ["term-2"]);
    assert_eq!(
        crate::page::last(&hub, "env-1", "terminal.close")["terminalId"],
        "term-1"
    );
}

#[test]
fn a_terminal_tab_goes_when_its_terminals_end() {
    let hub = crate::workspace::on_thread("main", None);
    hub.dispatch("rightPanel.add", json!({"kind": "terminal"}));
    hub.dispatch("rightPanel.add", json!({"kind": "diff"}));
    assert_eq!(titles(&hub), ["Terminal", "Diff"]);
    hub.mc.frame_where(
        &hub.engine,
        |shape| shape["type"] == "terminal" && shape["input"]["terminalId"] == "term-1",
        json!({"t": "terminal", "event": {"type": "exited"}}),
    );
    assert!(terminal_ids(&hub).is_empty());
    assert_eq!(titles(&hub), ["Diff"]);
}

#[test]
fn a_layout_with_nowhere_to_draw_a_terminal_cannot_add_one() {
    let hub = crate::workspace::on_thread("main", None);
    assert_eq!(panel(&hub)["canAdd"]["terminal"], true);
    hal_c2_shell::controllers::terminals::set_drawn(&hub.engine, false);
    assert_eq!(panel(&hub)["canAdd"]["terminal"], false);
    hub.dispatch("rightPanel.add", json!({"kind": "terminal"}));
    assert!(titles(&hub).iter().all(|t| t != "Terminal"));
    assert!(terminal_ids(&hub).is_empty());
}

fn launch(dir: &Path) -> Launch {
    Launch {
        state_dir: Some(dir.to_owned()),
        ..Launch::default()
    }
}

#[test]
fn the_panels_come_back_with_the_app() {
    let dir = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).unwrap();
    {
        let hub = hub_with(launch(dir.path()), &rows(&["t1", "t2"]));
        open(&hub, "t1");
        hub.dispatch("rightPanel.add", json!({"kind": "files"}));
        hub.dispatch("rightPanel.add", json!({"kind": "diff"}));
        hub.dispatch("rightPanel.activate", json!({"id": "files"}));
        hub.dispatch("rightPanel.resize", json!({"width": 700}));
        open(&hub, "t2");
        hub.dispatch("threadPanel.toggle", json!({}));
    }
    let stored: Json =
        serde_json::from_slice(&std::fs::read(dir.path().join("shell-panel.json")).unwrap())
            .unwrap();
    assert_eq!(stored["width"], 700);
    assert_eq!(
        stored["threads"],
        json!([
            {"threadKey": "env-1:t1", "open": true, "tabs": ["files", "diff"],
                "active": "files", "details": false, "dismissed": []},
            {"threadKey": "env-1:t2", "open": false, "tabs": [], "active": "",
                "details": true, "dismissed": []},
        ])
    );
    let hub = hub_with(launch(dir.path()), &rows(&["t1", "t2"]));
    open(&hub, "t1");
    assert_eq!(panel(&hub)["width"], 700);
    assert_eq!(panel(&hub)["isOpen"], true);
    assert_eq!(panel(&hub)["activeId"], "files");
    assert_eq!(titles(&hub), ["Files", "Diff"]);
    open(&hub, "t2");
    assert_eq!(panel(&hub)["detailsOpen"], true);
}

#[test]
fn a_stored_panel_shows_only_the_tabs_it_can() {
    let dir = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).unwrap();
    std::fs::write(
        dir.path().join("shell-panel.json"),
        json!({"width": 10, "threads": [{"threadKey": "env-1:t1", "open": true,
            "tabs": ["terminal:g1", "nonsense", "pull-request:x", "device:h:d", "previews"],
            "active": "terminal:g1"}]})
        .to_string(),
    )
    .unwrap();
    let hub = hub_with(launch(dir.path()), &rows(&["t1"]));
    open(&hub, "t1");
    assert_eq!(panel(&hub)["width"], 360);
    assert_eq!(titles(&hub), ["Device", "Previews"]);
    assert_eq!(panel(&hub)["activeId"], "device:h:d");
    assert_eq!(panel(&hub)["isOpen"], true);
}

#[test]
fn a_device_takes_the_pickers_place() {
    let hub = hub(&["t1"]);
    open(&hub, "t1");
    hub.dispatch("rightPanel.add", json!({"kind": "device"}));
    hub.with_controller::<RightPanel, _>(|p, e| p.open_device(e, "device:h:d", false));
    assert_eq!(titles(&hub), ["Device"]);
    assert_eq!(panel(&hub)["activeId"], "device:h:d");
    // Closed by the user, it does not come back on its own.
    hub.dispatch("rightPanel.close", json!({"id": "device:h:d"}));
    hub.with_controller::<RightPanel, _>(|p, e| p.open_device(e, "device:h:d", true));
    assert_eq!(titles(&hub), Vec::<String>::new());
    hub.with_controller::<RightPanel, _>(|p, e| p.open_device(e, "device:h:d", false));
    assert_eq!(titles(&hub), ["Device"]);
}

/// The files calls (`projects.*`) made so far, as "method key".
fn files_calls(hub: &Hub) -> Vec<String> {
    hub.mc
        .calls
        .borrow()
        .iter()
        .filter(|(_, m, _)| m.starts_with("projects."))
        // The project's settings file is read for the settings, not the tab.
        .filter(|(_, _, p)| p["relativePath"] != "hal-c2.json")
        .map(|(_, m, p)| {
            let key = ["directoryPath", "relativePath"]
                .iter()
                .find_map(|k| p.get(*k).and_then(Json::as_str))
                .unwrap_or("");
            format!("{} {key} {}", m.trim_start_matches("projects."), p["cwd"])
        })
        .collect()
}

#[test]
fn the_files_tab_lists_the_threads_checkout_while_it_shows() {
    let hub = hub(&["t1"]);
    open(&hub, "t1");
    assert!(files_calls(&hub).is_empty());
    hub.dispatch("rightPanel.add", json!({"kind": "files"}));
    assert_eq!(files_calls(&hub), ["listEntries  \"/work/p\""]);
    // Another tab hides it; showing it again does not list again.
    hub.dispatch("rightPanel.add", json!({"kind": "agents"}));
    hub.dispatch("rightPanel.activate", json!({"id": "files"}));
    assert_eq!(files_calls(&hub).len(), 1);
    // Closing the panel hides it too.
    hub.dispatch("rightPanel.toggle", json!({}));
    let files = hub.with_controller::<RightPanel, _>(|p, _| p.files().unwrap());
    let shown = WorkspaceFiles::read(&hub.engine, files, |f| f.is_active());
    assert_eq!(shown, Some(false));
}

#[test]
fn the_files_tab_follows_the_thread_shown() {
    let hub = hub_with(
        Launch::default(),
        &[
            json!({"id": "t1"}),
            json!({"id": "t2", "worktreePath": "/work/t2"}),
        ],
    );
    open(&hub, "t1");
    hub.dispatch("rightPanel.add", json!({"kind": "files"}));
    open(&hub, "t2");
    hub.dispatch("rightPanel.add", json!({"kind": "files"}));
    assert_eq!(
        files_calls(&hub),
        ["listEntries  \"/work/p\"", "listEntries  \"/work/t2\""]
    );
    let files = hub.with_controller::<RightPanel, _>(|p, _| p.files().unwrap());
    let root = WorkspaceFiles::read(&hub.engine, files, |f| f.root().to_owned());
    assert_eq!(root.as_deref(), Some("/work/t2"));
}

#[test]
fn opening_a_file_in_the_panel_reads_it_at_the_line() {
    let hub = hub(&["t1"]);
    open(&hub, "t1");
    hub.with_controller::<RightPanel, _>(|p, e| {
        p.open(e, "files", &json!({"path": "src/a.rs", "line": 3}));
    });
    assert_eq!(panel(&hub)["activeId"], "files");
    assert_eq!(
        files_calls(&hub),
        ["listEntries  \"/work/p\"", "readFile src/a.rs \"/work/p\""]
    );
    let files = hub.with_controller::<RightPanel, _>(|p, _| p.files().unwrap());
    let open = WorkspaceFiles::read(&hub.engine, files, |f| f.open_path().to_owned());
    assert_eq!(open.as_deref(), Some("src/a.rs"));
}

/// The environment's devices: an iPhone, with the thread's session when
/// `open`.
fn devices(name: &str, open: bool) -> Json {
    let sessions = if open {
        json!([{"deviceId": "UDID-1", "hostId": "host-1", "threadId": "t1"}])
    } else {
        json!([])
    };
    json!({"t": "devices", "state": {
        "bootingDevices": [],
        "devices": [{"booted": true, "hostId": "host-1", "id": "UDID-1", "name": name,
            "platform": "ios", "version": "iOS 26.0"}],
        "hostStatus": "ready",
        "hostStatuses": {"host-1": {"status": "ready"}},
        "hosts": [{"id": "host-1", "label": "studio",
            "platforms": [{"available": true, "platform": "ios"}]}],
        "hubBasePath": "/api/device-hub/mcs/a",
        "onboardingCompleted": true,
        "sessions": sessions,
    }})
}

#[test]
fn a_device_the_agent_opens_gets_a_tab_named_for_it() {
    let hub = hub(&["t1"]);
    open(&hub, "t1");
    hub.mc
        .frame(&hub.engine, "devices", "", devices("iPhone 17", false));
    let before = titles(&hub);
    hub.mc
        .frame(&hub.engine, "devices", "", devices("iPhone 17", true));
    let named = |name: &str| [before.clone(), vec![name.to_owned()]].concat();
    assert_eq!(titles(&hub), named("iPhone 17"));
    assert_eq!(panel(&hub)["activeId"], "device:host-1:UDID-1");
    // The device renamed renames the tab.
    hub.mc
        .frame(&hub.engine, "devices", "", devices("Olafur's iPhone", true));
    assert_eq!(titles(&hub), named("Olafur's iPhone"));
    // The session ending does not close it: the tab says the device is gone
    // until the user closes it.
    hub.mc.frame(
        &hub.engine,
        "devices",
        "",
        devices("Olafur's iPhone", false),
    );
    assert_eq!(titles(&hub), named("Olafur's iPhone"));
}

mod prop {
    use proptest::prelude::*;

    use super::*;

    /// What the user does, in any order.
    #[derive(Clone, Debug)]
    enum Op {
        Open(usize),
        Settings,
        Toggle,
        Add(&'static str),
        Activate(usize),
        Close(Option<usize>),
        Maximize,
        Details,
        Resize(Option<i32>),
    }

    const THREADS: [&str; 3] = ["t1", "t2", "t3"];
    const KINDS: [&str; 5] = ["diff", "files", "agents", "previews", "browser"];

    fn op() -> impl Strategy<Value = Op> {
        prop_oneof![
            2 => (0..THREADS.len()).prop_map(Op::Open),
            1 => Just(Op::Settings),
            2 => Just(Op::Toggle),
            3 => (0..KINDS.len()).prop_map(|k| Op::Add(KINDS[k])),
            2 => (0..4usize).prop_map(Op::Activate),
            2 => proptest::option::of(0..4usize).prop_map(Op::Close),
            1 => Just(Op::Maximize),
            1 => Just(Op::Details),
            1 => proptest::option::of(0..1000i32).prop_map(Op::Resize),
        ]
    }

    fn step(hub: &Hub, op: &Op) {
        let tab = |n: usize| {
            panel(hub)["tabs"]
                .get(n)
                .and_then(|t| t["id"].as_str())
                .unwrap_or("")
                .to_owned()
        };
        match op {
            Op::Open(t) => open(hub, THREADS[*t]),
            Op::Settings => hub.dispatch("settings.open", json!({})),
            Op::Toggle => hub.dispatch("rightPanel.toggle", json!({})),
            Op::Add(kind) => hub.dispatch("rightPanel.add", json!({"kind": kind})),
            Op::Activate(n) => hub.dispatch("rightPanel.activate", json!({"id": tab(*n)})),
            Op::Close(n) => {
                let id = n.map_or(String::new(), tab);
                hub.dispatch("rightPanel.close", json!({"id": id}))
            }
            Op::Maximize => hub.dispatch("rightPanel.toggleMaximized", json!({})),
            Op::Details => hub.dispatch("threadPanel.toggle", json!({})),
            Op::Resize(width) => match width {
                Some(w) => hub.dispatch("rightPanel.resize", json!({"width": w})),
                None => hub.dispatch("rightPanel.resize", json!({})),
            },
        }
    }

    /// What every published panel holds to.
    fn check(hub: &Hub) -> Result<(), TestCaseError> {
        let p = panel(hub);
        if p.is_null() {
            return Ok(());
        }
        let ids: Vec<&str> = p["tabs"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["id"].as_str().unwrap())
            .collect();
        let active = p["activeId"].as_str().unwrap();
        let mut unique = ids.clone();
        unique.sort();
        unique.dedup();
        prop_assert_eq!(unique.len(), ids.len(), "no tab twice: {}", p);
        prop_assert!(
            active.is_empty() || ids.contains(&active),
            "the active tab is a tab: {}",
            p
        );
        if p["isOpen"] == true {
            prop_assert!(
                !ids.is_empty() && !active.is_empty(),
                "an open panel shows a tab: {}",
                p
            );
        } else {
            prop_assert_eq!(
                &p["maximized"],
                &json!(false),
                "a closed panel fills nothing: {}",
                p
            );
        }
        prop_assert!(p["width"].as_i64().unwrap() >= 360);
        prop_assert_eq!(p["detailsOpen"] == true, !p["details"].is_null());
        Ok(())
    }

    proptest! {
        #![proptest_config(ProptestConfig { cases: 64, ..ProptestConfig::default() })]

        /// Each thread's panel is as the user left it, through any visits
        /// to other threads and to settings.
        #[test]
        fn each_thread_keeps_a_consistent_panel(ops in proptest::collection::vec(op(), 1..40)) {
            let hub = hub(&THREADS);
            let mut kept = std::collections::HashMap::<String, Json>::new();
            for op in &ops {
                step(&hub, op);
                check(&hub)?;
                let p = panel(&hub);
                if let Some(key) = p["threadKey"].as_str() {
                    let shown = json!([p["tabs"], p["activeId"], p["isOpen"], p["detailsOpen"]]);
                    if let (Op::Open(_), Some(before)) = (op, kept.get(key)) {
                        prop_assert_eq!(before, &shown, "{} came back as it was", key);
                    }
                    kept.insert(key.to_owned(), shown);
                }
            }
        }
    }
}
