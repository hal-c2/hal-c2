//! `navigation`: the route kept between runs, a thread that moved or went
//! away, a draft that is gone, titles that follow renames, the palette's
//! places and the plugin pages' tabs (NavigationController.cpp,
//! features/navigation/).

use std::path::Path;

use hal_c2_shell::Launch;
use hal_c2_shell::commands::Commands;
use hal_c2_shell::controllers::navigation::{self, Navigation, Route};
use hal_c2_shell::json::Json;
use hal_c2_shell::store;
use serde_json::json;

use crate::Hub;

pub(crate) const AT: &str = "2026-03-01T00:00:00Z";
pub(crate) const ORIGIN: &str = "http://127.0.0.1:1";
const FILE: &str = "plugins.file";

/// The MCs of a cluster: `(mc, environment)`, all online.
pub(crate) fn mcs(list: &[(&str, &str)]) -> Vec<Json> {
    list.iter()
        .map(|(mc, environment)| {
            json!({"mc": mc, "online": true, "epoch": "e", "rev": 1,
                "environment": {"environmentId": environment, "label": environment,
                    "capabilities": {}}})
        })
        .collect()
}

pub(crate) fn project(mc: &str, id: &str) -> Json {
    json!([mc, id, "project", {"id": id, "title": id, "workspaceRoot": format!("/work/{id}"),
        "createdAt": AT, "updatedAt": AT}])
}

pub(crate) fn thread(mc: &str, id: &str, title: &str) -> Json {
    json!([mc, id, "thread", {"id": id, "projectId": "p1", "title": title,
        "createdAt": AT, "updatedAt": AT,
        "modelSelection": {"instanceId": "claude", "model": "m"}}])
}

/// The MC's first `shell` frame.
pub(crate) fn shell(hub: &Hub, list: &[(&str, &str)], rows: Vec<Json>) {
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell", "mcs": mcs(list), "rows": rows}),
    );
    hub.advance(0);
}

/// Rows `env-1` has changed, as the MC sends them.
pub(crate) fn rows(hub: &Hub, mc: &str, rev: u32, rows: Vec<Json>) {
    let rows: Vec<Json> = rows
        .into_iter()
        .map(|row| json!([row[1], row[2], row[3]]))
        .collect();
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell.rows", "mc": mc, "epoch": "e", "rev": rev, "rows": rows}),
    );
    hub.advance(0);
}

/// A shell over the MC and nothing kept.
fn plain() -> Launch {
    Launch {
        mc_origin: Some(ORIGIN.into()),
        ..Launch::default()
    }
}

pub(crate) fn launch(state: &Path) -> Launch {
    Launch {
        mc_origin: Some(ORIGIN.into()),
        state_dir: Some(state.to_owned()),
        ..Launch::default()
    }
}

/// A hub over `launch` whose MC has answered with env-1 holding project p1
/// and the threads `(id, title)`.
fn hub_with(launch: Launch, threads: &[(&str, &str)]) -> Hub {
    let hub = Hub::with(launch);
    hub.mc.set_ready(&hub.engine, true);
    let mut list = vec![project("a", "p1")];
    list.extend(threads.iter().map(|(id, title)| thread("a", id, title)));
    shell(&hub, &[("a", "env-1")], list);
    hub
}

pub(crate) fn state() -> tempfile::TempDir {
    tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).unwrap()
}

pub(crate) fn route(hub: &Hub) -> Json {
    hub.published("route")
}

pub(crate) fn kind(hub: &Hub) -> String {
    route(hub)["kind"].as_str().unwrap_or_default().to_owned()
}

fn open(hub: &Hub, key: &str) {
    hub.dispatch("thread.open", json!({"key": key}));
}

fn run(hub: &Hub, command: &str) {
    assert!(
        Commands::of(&hub.engine).run(&hub.engine, command),
        "{command} runs"
    );
    hub.advance(0);
}

pub(crate) fn saved(dir: &Path) -> Json {
    serde_json::from_slice(&std::fs::read(dir.join("shell-route.json")).unwrap()).unwrap()
}

#[test]
fn the_route_comes_back_with_the_app() {
    let dir = state();
    {
        let hub = hub_with(launch(dir.path()), &[("t1", "One"), ("t2", "Two")]);
        open(&hub, "env-1:t2");
        assert_eq!(saved(dir.path())["threadKey"], "env-1:t2");
    }
    let hub = hub_with(launch(dir.path()), &[("t1", "One"), ("t2", "Two")]);
    assert_eq!(kind(&hub), "thread");
    assert_eq!(route(&hub)["threadKey"], "env-1:t2");
    assert_eq!(route(&hub)["title"], "Two");
    assert!(
        !route(&hub)["canGoBack"].as_bool().unwrap(),
        "a restored route has no history"
    );
}

#[test]
fn a_settings_section_comes_back_and_each_change_is_saved() {
    let dir = state();
    {
        let hub = hub_with(launch(dir.path()), &[("t1", "One")]);
        hub.dispatch("settings.navigate", json!({"to": "/settings/archived"}));
        assert_eq!(saved(dir.path())["kind"], "settings");
        assert_eq!(saved(dir.path())["section"], "/settings/archived");
    }
    let hub = hub_with(launch(dir.path()), &[("t1", "One")]);
    assert!(navigation::at_section(&route(&hub), "/settings/archived"));
    hub.dispatch("usage.open", json!({}));
    assert_eq!(saved(dir.path())["kind"], "usage");
}

/// A settings page the app was closed on shows its content when it comes
/// back: the page's controller activates after the route is restored and
/// must read it, not wait for the next navigation.
#[test]
fn a_settings_page_restored_with_the_app_is_open() {
    for (key, section) in [
        ("deviceSettings", "/settings/integrations"),
        ("projectSettings", "/settings/projects"),
        ("scheduledTasks", "/settings/scheduled-tasks"),
        ("sourceControlSettings", "/settings/source-control"),
    ] {
        let dir = state();
        std::fs::write(
            dir.path().join("shell-route.json"),
            json!({"kind": "settings", "section": section}).to_string(),
        )
        .unwrap();
        let hub = hub_with(launch(dir.path()), &[("t1", "One")]);
        assert!(navigation::at_section(&route(&hub), section), "{section}");
        assert_eq!(hub.published(key)["open"], true, "{key} at {section}");
    }
}

#[test]
fn a_file_that_names_no_route_starts_at_home() {
    let dir = state();
    for text in [
        "",
        "not json",
        r#"{"kind": "elsewhere"}"#,
        r#"{"kind": "thread"}"#,
    ] {
        std::fs::write(dir.path().join("shell-route.json"), text).unwrap();
        // No project, so nothing to land a draft on.
        let hub = Hub::with(launch(dir.path()));
        hub.mc.set_ready(&hub.engine, true);
        shell(&hub, &[("a", "env-1")], vec![]);
        assert_eq!(kind(&hub), "home", "{text:?}");
    }
}

#[test]
fn a_thread_deleted_since_is_dropped_but_one_of_an_unserved_environment_waits() {
    let dir = state();
    std::fs::write(
        dir.path().join("shell-route.json"),
        r#"{"kind": "thread", "threadKey": "env-1:gone"}"#,
    )
    .unwrap();
    let hub = Hub::with(launch(dir.path()));
    hub.mc.set_ready(&hub.engine, true);
    shell(&hub, &[("a", "env-1")], vec![]);
    assert_eq!(kind(&hub), "home");
    assert_eq!(saved(dir.path())["kind"], "home");

    std::fs::write(
        dir.path().join("shell-route.json"),
        r#"{"kind": "thread", "threadKey": "env-9:away"}"#,
    )
    .unwrap();
    let hub = Hub::with(launch(dir.path()));
    hub.mc.set_ready(&hub.engine, true);
    shell(&hub, &[("a", "env-1")], vec![]);
    assert_eq!(route(&hub)["threadKey"], "env-9:away", "its MC may come");
}

#[test]
fn a_thread_that_moved_since_opens_where_it_lives() {
    let dir = state();
    std::fs::write(
        dir.path().join("shell-route.json"),
        r#"{"kind": "thread", "threadKey": "env-1:t1"}"#,
    )
    .unwrap();
    let hub = Hub::with(launch(dir.path()));
    hub.mc.set_ready(&hub.engine, true);
    let record = json!(["a", "t1", "thread", {"id": "t1", "projectId": "p1",
        "movedTo": {"environmentId": "env-2"}}]);
    shell(
        &hub,
        &[("a", "env-1"), ("b", "env-2")],
        vec![project("b", "p1"), record, thread("b", "t1", "Moved")],
    );
    assert_eq!(route(&hub)["threadKey"], "env-2:t1");
    assert_eq!(route(&hub)["title"], "Moved");
    assert_eq!(saved(dir.path())["threadKey"], "env-2:t1");

    // A key from before the move (a link, a notification) goes there too.
    hub.dispatch("settings.open", json!({}));
    hub.dispatch("link.open", json!({"url": "hal-c2://thread/env-1/t1"}));
    assert_eq!(route(&hub)["threadKey"], "env-2:t1");
}

#[test]
fn a_draft_that_was_sent_or_deleted_is_not_come_back_to() {
    let dir = state();
    let data = state();
    let with_data = |dir: &Path| Launch {
        data_dir: Some(data.path().to_owned()),
        ..launch(dir)
    };
    let id = {
        let hub = hub_with(with_data(dir.path()), &[]);
        hub.dispatch("thread.new", json!({}));
        assert_eq!(kind(&hub), "draft");
        route(&hub)["draftId"].as_str().unwrap().to_owned()
    };
    let hub = hub_with(with_data(dir.path()), &[]);
    assert_eq!(route(&hub)["draftId"], id.as_str(), "the draft is kept");

    std::fs::remove_file(data.path().join("shell-drafts.json")).unwrap();
    let hub = hub_with(with_data(dir.path()), &[]);
    // Home is not stayed at: the window lands on a draft of its own.
    assert_eq!(kind(&hub), "draft");
    assert_ne!(route(&hub)["draftId"], id.as_str());
}

#[test]
fn the_restored_route_is_not_landed_over() {
    let dir = state();
    {
        let hub = hub_with(launch(dir.path()), &[("t1", "One")]);
        open(&hub, "env-1:t1");
    }
    let hub = hub_with(launch(dir.path()), &[("t1", "One")]);
    assert_eq!(route(&hub)["threadKey"], "env-1:t1");
    // Nothing started a draft over it.
    assert!(hal_c2_shell::controllers::drafts::all(&hub.engine).is_empty());
}

#[test]
fn only_a_thread_the_cache_lists_shows_before_the_mc_answers() {
    let state = state();
    let cache = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).unwrap();
    let with_cache = || Launch {
        cache_dir: Some(cache.path().to_owned()),
        ..launch(state.path())
    };
    {
        let hub = hub_with(with_cache(), &[("t1", "One")]);
        open(&hub, "env-1:t1");
        store::flush(&hub.engine);
    }
    // The MC has not answered: the cache's rows are what there is.
    let hub = Hub::with(with_cache());
    assert_eq!(route(&hub)["threadKey"], "env-1:t1");
    assert_eq!(route(&hub)["title"], "One");

    std::fs::write(
        state.path().join("shell-route.json"),
        r#"{"kind": "thread", "threadKey": "env-1:unlisted"}"#,
    )
    .unwrap();
    let hub = Hub::with(with_cache());
    assert_eq!(route(&hub), Json::Null, "the cache does not list it");
}

#[test]
fn the_title_follows_a_rename_and_a_deleted_thread_leaves_home() {
    let hub = hub_with(plain(), &[("t1", "One"), ("t2", "Two")]);
    open(&hub, "env-1:t1");
    assert_eq!(route(&hub)["title"], "One");

    rows(&hub, "a", 2, vec![thread("a", "t1", "Renamed")]);
    assert_eq!(route(&hub)["title"], "Renamed");
    assert_eq!(route(&hub)["threadKey"], "env-1:t1");

    rows(
        &hub,
        "a",
        3,
        vec![json!(["a", "t1", "thread", {"id": "t1", "deletedAt": AT}])],
    );
    assert_eq!(kind(&hub), "draft", "home lands on the project's draft");
    // Back from there does not return to it.
    open(&hub, "env-1:t2");
    hub.with_controller::<Navigation, _>(|n, e| n.back(e));
    assert_ne!(route(&hub)["threadKey"], "env-1:t1");
}

#[test]
fn a_thread_that_moves_away_is_followed_there() {
    let hub = Hub::with(Launch {
        mc_origin: Some(ORIGIN.into()),
        ..Launch::default()
    });
    hub.mc.set_ready(&hub.engine, true);
    shell(
        &hub,
        &[("a", "env-1"), ("b", "env-2")],
        vec![project("a", "p1"), thread("a", "t1", "One")],
    );
    open(&hub, "env-1:t1");
    rows(
        &hub,
        "b",
        2,
        vec![project("b", "p1"), thread("b", "t1", "One")],
    );
    rows(
        &hub,
        "a",
        2,
        vec![json!(["a", "t1", "thread", {"id": "t1", "projectId": "p1",
            "movedTo": {"environmentId": "env-2"}}])],
    );
    assert_eq!(route(&hub)["threadKey"], "env-2:t1");
}

#[test]
fn a_plugin_threads_route_names_its_plugin() {
    let hub = hub_with(plain(), &[]);
    rows(
        &hub,
        "a",
        2,
        vec![
            json!(["a", "r1", "thread", {"id": "r1", "projectId": "p1", "title": "Review",
            "createdAt": AT, "updatedAt": AT,
            "plugin": {"id": "reviews", "kind": "review", "listed": false}}]),
        ],
    );
    open(&hub, "env-1:r1");
    assert_eq!(
        route(&hub)["plugin"],
        json!({"id": "reviews", "kind": "review"})
    );
    hub.dispatch("usage.open", json!({}));
    assert_eq!(route(&hub)["plugin"], Json::Null);
}

#[test]
fn the_palette_offers_settings_usage_and_pull_requests() {
    let hub = hub_with(plain(), &[("t1", "One")]);
    let commands = Commands::of(&hub.engine);
    let row = |id: &str| {
        commands
            .rows()
            .into_iter()
            .find(|r| r.command == id)
            .unwrap_or_else(|| panic!("{id} is in the palette"))
    };
    assert_eq!(row("settings.open").title, "Open settings");
    assert_eq!(row("usage.open").title, "Open usage");
    assert_eq!(row("pullRequests.open").title, "Open pull requests");
    assert!(row("settings.open").terms.contains(&"preferences".into()));
    assert!(row("usage.open").terms.contains(&"tokens".into()));
    assert!(row("pullRequests.open").terms.contains(&"prs".into()));
    assert!(
        !row("pullRequests.open").listed,
        "no source control provider yet"
    );

    run(&hub, "usage.open");
    assert_eq!(kind(&hub), "usage");
    assert_eq!(route(&hub)["title"], "Usage");
    run(&hub, "pullRequests.open");
    assert_eq!(kind(&hub), "pullRequests");
    run(&hub, "settings.open");
    assert_eq!(kind(&hub), "settings");
    assert_eq!(route(&hub)["title"], "Settings");
    hub.dispatch("settings.back", json!({}));
    assert_eq!(kind(&hub), "pullRequests");
}

#[test]
fn pull_requests_are_listed_once_an_environment_supports_them() {
    let hub = Hub::with(plain());
    hub.mc.set_ready(&hub.engine, true);
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell", "rows": [], "mcs": [{"mc": "a", "online": true, "epoch": "e",
            "rev": 1, "environment": {"environmentId": "env-1", "label": "env-1",
                "capabilities": {"sourceControlProviders": ["github"]}}}]}),
    );
    hub.advance(0);
    let listed = |hub: &Hub| {
        Commands::of(&hub.engine)
            .rows()
            .into_iter()
            .find(|r| r.command == "pullRequests.open")
            .unwrap()
            .listed
    };
    // Whatever the capability is called, it is the store that says.
    let supported = store::with(&hub.engine, |s| s.supports("env-1", "pullRequests"));
    assert_eq!(listed(&hub), supported);
}

// ---- Plugin pages ----------------------------------------------------------

fn reviews(revision: &str, page: &str) -> Json {
    json!({"id": "reviews", "name": "Reviews", "revision": revision, "status": "running",
        "contributes": {"pages": [{"id": page, "title": "Inbox", "icon": "inbox",
            "qml": "Inbox.qml"}]}})
}

/// `list` is what `environment` runs now, at `revision`; its files come at
/// once.
fn plugins(hub: &Hub, environment: &str, revision: &str, list: Vec<Json>) {
    hub.mc.frame(
        &hub.engine,
        "plugins",
        environment,
        json!({"t": "plugins", "plugins": list}),
    );
    let total = hub.mc.calls.borrow().len();
    for i in 0..total {
        let wanted = hub.mc.calls.borrow()[i].1 == FILE;
        if wanted {
            hub.mc.reply(
                &hub.engine,
                i,
                Ok(json!({"revision": revision, "encoding": "utf8", "content": "Item {}"})),
            );
        }
    }
    hub.advance(0);
}

fn tab(hub: &Hub) -> String {
    route(hub)["tab"].as_str().unwrap().to_owned()
}

#[test]
fn a_plugin_page_is_a_tab_with_its_own_title_and_the_keys_step_through_them() {
    let hub = hub_with(plain(), &[("t1", "One")]);
    open(&hub, "env-1:t1");
    let commands = Commands::of(&hub.engine);
    let listed = |id: &str| commands.rows().into_iter().find(|r| r.command == id);
    assert!(!listed("tabs.next").unwrap().listed, "nothing to step to");

    plugins(&hub, "env-1", "r1", vec![reviews("r1", "inbox")]);
    assert_eq!(tab(&hub), "threads");
    let key = "reviews/inbox@r1";
    assert!(listed("tabs.next").unwrap().listed);
    let open_tab = listed(&format!("tabs.open:{key}")).expect("the page is in the palette");
    assert_eq!(open_tab.title, "Inbox");
    assert!(open_tab.terms.contains(&"Reviews".into()));

    run(&hub, &format!("tabs.open:{key}"));
    assert_eq!(tab(&hub), key);
    assert_eq!(route(&hub)["title"], "Inbox");
    assert_eq!(route(&hub)["threadKey"], "env-1:t1", "the route is kept");

    // Settings show over the tab and a tab is chosen to be seen.
    hub.dispatch("settings.open", json!({}));
    assert_eq!(route(&hub)["title"], "Settings");
    run(&hub, "tabs.next");
    assert_eq!(kind(&hub), "thread");
    assert_eq!(tab(&hub), "threads", "next wraps");
    run(&hub, "tabs.previous");
    assert_eq!(tab(&hub), key);

    // What the user opens shows in the threads.
    open(&hub, "env-1:t1");
    hub.dispatch("usage.open", json!({}));
    assert_eq!(tab(&hub), "threads");
    hub.dispatch("tabs.select", json!({"key": "no/such@page"}));
    assert_eq!(tab(&hub), "threads");
}

#[test]
fn a_tab_follows_its_page_to_the_next_version_and_leaves_with_the_plugin() {
    let hub = hub_with(plain(), &[]);
    plugins(&hub, "env-1", "r1", vec![reviews("r1", "inbox")]);
    hub.dispatch("tabs.select", json!({"key": "reviews/inbox@r1"}));
    assert_eq!(tab(&hub), "reviews/inbox@r1");

    plugins(&hub, "env-1", "r2", vec![reviews("r2", "inbox")]);
    assert_eq!(
        tab(&hub),
        "reviews/inbox@r2",
        "the update keeps the user on it"
    );
    assert!(
        Commands::of(&hub.engine)
            .rows()
            .iter()
            .all(|r| r.command != "tabs.open:reviews/inbox@r1")
    );

    plugins(&hub, "env-1", "r2", vec![]);
    assert_eq!(tab(&hub), "threads");
    assert!(
        !Commands::of(&hub.engine)
            .rows()
            .iter()
            .any(|r| r.command == "tabs.open:reviews/inbox@r2")
    );
}

#[test]
fn navigation_reads_back_what_it_shows() {
    let hub = hub_with(plain(), &[("t1", "One")]);
    open(&hub, "env-1:t1");
    hub.with_controller::<Navigation, _>(|n, _| {
        assert_eq!(n.route(), &Route::Thread("env-1:t1".into()));
        assert_eq!(n.thread_key(), "env-1:t1");
        assert_eq!(n.tab(), "threads");
    });
}
