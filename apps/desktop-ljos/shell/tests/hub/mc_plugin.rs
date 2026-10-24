//! `mcPlugins`: the plugins each environment's MC runs, their files fetched
//! and kept by revision, and the singleton their UI parts talk through
//! (McPluginController.cpp, features/plugins/).

use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::rc::Rc;

use hal_c2_shell::Launch;
use hal_c2_shell::controllers::mc_plugin::{
    McPluginsObject, keeps_unlisted, on_pages_changed, on_running_changed, pages,
};
use hal_c2_shell::json::{self, Json};
use hal_c2_shell::mc::McError;
use ljos::prelude::Value;
use serde_json::json;

use crate::Hub;
use crate::common::{call, js_value};

const FILE: &str = "plugins.file";

fn cache_dir(test: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join("hub-mc-plugin")
        .join(test);
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

/// A hub over `env-1` ("Laptop") and `env-2` ("Server"), both online.
fn hub(test: &str) -> (Hub, PathBuf) {
    let dir = cache_dir(test);
    let hub = Hub::with(Launch {
        mc_origin: Some("http://127.0.0.1:1".into()),
        cache_dir: Some(dir.clone()),
        ..Launch::default()
    });
    cluster(&hub, true);
    (hub, dir.join("mc-plugins"))
}

fn cluster(hub: &Hub, server_online: bool) {
    let mc = |name: &str, environment: &str, label: &str, online: bool| {
        json!({"mc": name, "online": online, "epoch": "e", "rev": 1,
            "environment": {"environmentId": environment, "label": label}})
    };
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell", "mcs": [mc("a", "env-1", "Laptop", true), mc("b", "env-2", "Server", server_online)], "rows": []}),
    );
}

fn state(hub: &Hub) -> Json {
    hub.published("mcPlugins")
}

fn plugins(hub: &Hub, environment: &str, list: Vec<Json>) {
    hub.mc.frame(
        &hub.engine,
        "plugins",
        environment,
        json!({"t": "plugins", "plugins": list}),
    );
}

/// A running plugin with a page, a thread kind and a slot.
fn reviews(revision: &str) -> Json {
    json!({
        "id": "reviews", "name": "Reviews", "revision": revision, "status": "running",
        "icon": "icon.svg",
        "contributes": {
            "pages": [{"id": "inbox", "title": "Inbox", "icon": "inbox", "qml": "Inbox.qml"}],
            "threadKinds": [{"kind": "review", "label": "Review", "rowMark": "Mark.qml", "header": "Header.qml"}],
            "slots": [{"slot": "composer", "qml": "Slot.qml", "order": 2}],
        },
    })
}

fn asked(hub: &Hub, environment: &str) -> Vec<String> {
    hub.mc
        .calls
        .borrow()
        .iter()
        .filter(|(e, m, _)| e == environment && m == FILE)
        .map(|(_, _, input)| input["path"].as_str().unwrap().to_owned())
        .collect()
}

/// Answers the oldest `plugins.file` of `path` on `environment` not answered
/// yet; false when there is none.
fn serve(hub: &Hub, environment: &str, path: &str, revision: &str, content: &str) -> bool {
    let total = hub.mc.calls.borrow().len();
    (0..total).any(|i| {
        let wanted = {
            let calls = hub.mc.calls.borrow();
            calls[i].0 == environment && calls[i].1 == FILE && calls[i].2["path"] == path
        };
        wanted
            && hub.mc.reply(
                &hub.engine,
                i,
                Ok(json!({"revision": revision, "encoding": "utf8", "content": content})),
            )
    })
}

fn serve_all(hub: &Hub, environment: &str, revision: &str) {
    for path in asked(hub, environment) {
        serve(hub, environment, &path, revision, &format!("// {path}"));
    }
}

fn toast_titles(hub: &Hub) -> Vec<String> {
    hub.published("toasts")["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["title"].as_str().unwrap().to_owned())
        .collect()
}

fn last(hub: &Hub, method: &str) -> (String, Json) {
    hub.mc
        .calls
        .borrow()
        .iter()
        .rev()
        .find(|c| c.1 == method)
        .map(|c| (c.0.clone(), c.2.clone()))
        .unwrap_or_else(|| panic!("{method} was not called"))
}

fn count(hub: &Hub, method: &str) -> usize {
    hub.mc.methods().iter().filter(|m| *m == method).count()
}

#[test]
fn every_online_environment_is_followed_and_one_that_goes_offline_takes_its_plugins() {
    let (hub, _) = hub("follow");
    let shapes: Vec<Json> = hub
        .mc
        .subscriptions()
        .into_iter()
        .map(|(_, s)| s)
        .filter(|s| s["type"] == "plugins")
        .collect();
    assert_eq!(shapes.len(), 2);
    plugins(
        &hub,
        "env-1",
        vec![json!({"id": "a", "revision": "1", "status": "stopped"})],
    );
    plugins(
        &hub,
        "env-2",
        vec![json!({"id": "b", "revision": "1", "status": "stopped"})],
    );
    let ids = |hub: &Hub| -> Vec<String> {
        state(hub)["environments"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e["id"].as_str().unwrap().to_owned())
            .collect()
    };
    assert_eq!(ids(&hub), ["env-1", "env-2"]);
    assert_eq!(state(&hub)["environments"][1]["label"], "Server");

    cluster(&hub, false);
    assert_eq!(ids(&hub), ["env-1"]);
    let followed = hub
        .mc
        .subscriptions()
        .into_iter()
        .filter(|(_, s)| s["type"] == "plugins")
        .count();
    assert_eq!(followed, 1);
}

#[test]
fn a_page_shows_once_all_the_files_of_its_plugin_have_come_and_they_are_kept() {
    let (hub, cache) = hub("files");
    plugins(&hub, "env-1", vec![reviews("r1")]);
    let mut paths = asked(&hub, "env-1");
    paths.sort();
    assert_eq!(
        paths,
        [
            "Header.qml",
            "Inbox.qml",
            "Mark.qml",
            "Slot.qml",
            "icon.svg"
        ]
    );
    assert_eq!(state(&hub)["pages"][0]["url"], "", "on its way");
    assert_eq!(state(&hub)["slots"], json!([]));

    assert!(serve(&hub, "env-1", "Inbox.qml", "r1", "Item {}"));
    assert_eq!(
        state(&hub)["pages"][0]["url"],
        "",
        "none shows until all have come"
    );
    for path in ["Header.qml", "Mark.qml", "Slot.qml", "icon.svg"] {
        serve(&hub, "env-1", path, "r1", "x");
    }
    let shown = state(&hub);
    let page = &shown["pages"][0];
    assert_eq!(page["key"], "reviews/inbox@r1");
    assert_eq!(page["title"], "Inbox");
    assert_eq!(page["pluginName"], "Reviews");
    assert_eq!(page["environments"], json!(["env-1"]));
    let kept = cache.join("env-1/reviews/r1/running/Inbox.qml");
    assert_eq!(std::fs::read_to_string(&kept).unwrap(), "Item {}");
    assert_eq!(page["url"], format!("file://{}", kept.display()));
    assert_eq!(
        shown["environments"][0]["plugins"][0]["iconUrl"],
        format!(
            "file://{}",
            cache.join("env-1/reviews/r1/running/icon.svg").display()
        )
    );
    let kinds = &shown["threadKinds"]["env-1/reviews/review"];
    assert_eq!(kinds["label"], "Review");
    assert!(kinds["rowMark"].as_str().unwrap().ends_with("/Mark.qml"));
    assert_eq!(shown["slots"][0]["slot"], "composer");
    assert_eq!(shown["slots"][0]["order"], 2);
    assert_eq!(pages(&hub.engine).len(), 1);
}

#[test]
fn a_file_is_not_asked_for_again_and_a_new_revision_replaces_the_old_ones_files() {
    let (hub, cache) = hub("revisions");
    plugins(&hub, "env-1", vec![reviews("r1")]);
    serve_all(&hub, "env-1", "r1");
    let asks = count(&hub, FILE);
    plugins(&hub, "env-1", vec![reviews("r1")]);
    assert_eq!(count(&hub, FILE), asks);

    plugins(&hub, "env-1", vec![reviews("r2")]);
    assert_eq!(count(&hub, FILE), asks * 2);
    assert_eq!(
        state(&hub)["pages"][0]["url"],
        "",
        "the new version is loaded from its own files"
    );
    serve_all(&hub, "env-1", "r2");
    assert!(!cache.join("env-1/reviews/r1").exists());
    assert!(cache.join("env-1/reviews/r2/running/Inbox.qml").exists());
    assert_eq!(state(&hub)["pages"][0]["key"], "reviews/inbox@r2");
}

#[test]
fn a_kept_file_is_used_without_asking_and_a_late_answer_of_an_older_revision_is_ignored() {
    let (hub, cache) = hub("kept");
    plugins(&hub, "env-1", vec![reviews("r1")]);
    serve_all(&hub, "env-1", "r1");
    let before = count(&hub, FILE);
    // A second run of the app finds the files where they were left.
    let again = Hub::with(Launch {
        mc_origin: Some("http://127.0.0.1:1".into()),
        cache_dir: cache.parent().map(Path::to_path_buf),
        ..Launch::default()
    });
    cluster(&again, true);
    plugins(&again, "env-1", vec![reviews("r1")]);
    assert_eq!(again.mc.methods().iter().filter(|m| *m == FILE).count(), 0);
    assert_ne!(before, 0);
    assert!(
        state(&again)["pages"][0]["url"]
            .as_str()
            .unwrap()
            .ends_with("/Inbox.qml")
    );

    // An answer for a revision the plugin has left is not kept.
    plugins(&hub, "env-1", vec![reviews("r2")]);
    let stale = hub.mc.pending(FILE).unwrap();
    hub.mc.reply(
        &hub.engine,
        stale,
        Ok(json!({"revision": "r1", "encoding": "utf8", "content": "old"})),
    );
    assert_eq!(state(&hub)["pages"][0]["url"], "");
}

#[test]
fn a_file_that_cannot_be_fetched_says_why_and_stays_failed_until_the_plugin_changes() {
    let (hub, _) = hub("failed");
    plugins(&hub, "env-1", vec![reviews("r1")]);
    for path in ["Header.qml", "Mark.qml", "Slot.qml", "icon.svg"] {
        serve(&hub, "env-1", path, "r1", "x");
    }
    let index = hub.mc.pending(FILE).unwrap();
    hub.mc
        .reply(&hub.engine, index, Err(McError::new("No such file")));
    assert_eq!(state(&hub)["pages"][0]["error"], "No such file");
    let asks = count(&hub, FILE);
    plugins(&hub, "env-1", vec![reviews("r1")]);
    assert_eq!(
        count(&hub, FILE),
        asks,
        "the list's other news does not retry it"
    );
    assert_eq!(state(&hub)["pages"][0]["error"], "No such file");
}

#[test]
fn base64_files_are_decoded() {
    let (hub, cache) = hub("base64");
    plugins(
        &hub,
        "env-1",
        vec![json!({"id": "p", "revision": "1", "status": "stopped", "icon": "icon.png"})],
    );
    let index = hub.mc.pending(FILE).unwrap();
    hub.mc.reply(
        &hub.engine,
        index,
        Ok(json!({"revision": "1", "encoding": "base64", "content": "aGk="})),
    );
    assert_eq!(
        std::fs::read(cache.join("env-1/p/1/listed/icon.png")).unwrap(),
        b"hi"
    );
    assert!(
        state(&hub)["environments"][0]["plugins"][0]["iconUrl"]
            .as_str()
            .unwrap()
            .ends_with("/listed/icon.png")
    );
}

#[test]
fn a_plugin_that_does_not_run_offers_no_pages_but_shows_its_icon() {
    let (hub, _) = hub("stopped");
    let mut stopped = reviews("r1");
    stopped["status"] = json!("stopped");
    plugins(&hub, "env-1", vec![stopped]);
    assert_eq!(asked(&hub, "env-1"), ["icon.svg"]);
    serve_all(&hub, "env-1", "r1");
    let shown = state(&hub);
    assert_eq!(shown["pages"], json!([]));
    assert_eq!(shown["threadKinds"], json!({}));
    assert_eq!(shown["slots"], json!([]));
    assert!(
        shown["environments"][0]["plugins"][0]["iconUrl"]
            .as_str()
            .unwrap()
            .ends_with("/icon.svg")
    );
}

#[test]
fn environments_on_one_revision_share_a_tab_and_one_on_another_gets_its_own() {
    let (hub, _) = hub("tabs");
    plugins(&hub, "env-1", vec![reviews("r1")]);
    plugins(&hub, "env-2", vec![reviews("r1")]);
    serve_all(&hub, "env-1", "r1");
    serve_all(&hub, "env-2", "r1");
    let shown = state(&hub);
    assert_eq!(shown["pages"].as_array().unwrap().len(), 1);
    assert_eq!(shown["pages"][0]["environments"], json!(["env-1", "env-2"]));
    assert_eq!(shown["pages"][0]["title"], "Inbox");

    plugins(&hub, "env-2", vec![reviews("r2")]);
    serve_all(&hub, "env-2", "r2");
    let shown = state(&hub);
    let titles: Vec<&str> = shown["pages"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["title"].as_str().unwrap())
        .collect();
    assert_eq!(titles, ["Inbox · Laptop", "Inbox · Server"]);
}

/// The url the tab of `reviews`' inbox shows, empty while none is ready.
fn tab_url(hub: &Hub) -> String {
    state(hub)["pages"][0]["url"]
        .as_str()
        .unwrap_or_default()
        .to_owned()
}

fn copy_of(cache: &Path, environment: &str) -> String {
    format!(
        "file://{}",
        cache
            .join(environment)
            .join("reviews/r1/running/Inbox.qml")
            .display()
    )
}

/// Two environments run one revision; whichever one's copy is ready first is
/// the one the tab shows, and the other becoming ready later leaves it alone,
/// so the open page is not made anew.
#[test]
fn a_tab_keeps_the_copy_it_shows_when_another_environments_copy_gets_ready() {
    for (first, second) in [("env-1", "env-2"), ("env-2", "env-1")] {
        let (hub, cache) = hub(&format!("tab-keeps-{first}"));
        plugins(&hub, "env-1", vec![reviews("r1")]);
        plugins(&hub, "env-2", vec![reviews("r1")]);
        assert_eq!(tab_url(&hub), "", "nothing is ready");
        serve_all(&hub, first, "r1");
        assert_eq!(tab_url(&hub), copy_of(&cache, first));
        serve_all(&hub, second, "r1");
        assert_eq!(
            tab_url(&hub),
            copy_of(&cache, first),
            "{second} getting ready leaves the tab on {first}'s copy"
        );
        assert_eq!(
            state(&hub)["pages"][0]["environments"],
            json!(["env-1", "env-2"])
        );
    }
}

#[test]
fn a_tab_whose_copy_goes_away_moves_to_one_that_is_ready() {
    let (hub, cache) = hub("tab-moves");
    plugins(&hub, "env-1", vec![reviews("r1")]);
    plugins(&hub, "env-2", vec![reviews("r1")]);
    serve_all(&hub, "env-2", "r1");
    serve_all(&hub, "env-1", "r1");
    assert_eq!(tab_url(&hub), copy_of(&cache, "env-2"));
    cluster(&hub, false);
    assert_eq!(tab_url(&hub), copy_of(&cache, "env-1"));
}

mod tab_prop {
    use super::*;
    use proptest::prelude::*;

    const NAMES: [&str; 2] = ["env-1", "env-2"];

    #[derive(Clone, Copy, Debug)]
    enum Move {
        /// The environment's MC reports its plugins.
        Announce(usize),
        /// Its files arrive.
        Serve(usize),
        /// The second environment goes offline, or comes back.
        Leave,
        Return,
    }

    fn moves() -> impl Strategy<Value = Move> {
        prop_oneof![
            (0..2usize).prop_map(Move::Announce),
            (0..2usize).prop_map(Move::Serve),
            Just(Move::Leave),
            Just(Move::Return),
        ]
    }

    /// What is true of the environments: told of its plugins, files kept
    /// (they stay on disk), online.
    #[derive(Default)]
    struct Model {
        announced: [bool; 2],
        ready: [bool; 2],
        away: bool,
        shown: Option<usize>,
    }

    impl Model {
        fn visible(&self, at: usize) -> bool {
            self.announced[at] && self.ready[at] && !(at == 1 && self.away)
        }

        /// The copy the tab shows: the one it had while that is ready,
        /// otherwise the first that is.
        fn settle(&mut self) {
            if self.shown.is_some_and(|at| self.visible(at)) {
                return;
            }
            self.shown = (0..2).find(|&at| self.visible(at));
        }
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(48))]

        #[test]
        fn the_tab_shows_a_ready_copy_and_keeps_it_while_it_is(
            steps in proptest::collection::vec(moves(), 1..30),
        ) {
            let (hub, cache) = hub("tab-prop");
            let mut model = Model::default();
            for step in steps {
                match step {
                    Move::Announce(at) if !(at == 1 && model.away) => {
                        plugins(&hub, NAMES[at], vec![reviews("r1")]);
                        model.announced[at] = true;
                    }
                    Move::Serve(at) if model.announced[at] && !(at == 1 && model.away) => {
                        serve_all(&hub, NAMES[at], "r1");
                        model.ready[at] = true;
                    }
                    Move::Leave if !model.away => {
                        cluster(&hub, false);
                        model.away = true;
                        model.announced[1] = false;
                    }
                    Move::Return if model.away => {
                        cluster(&hub, true);
                        model.away = false;
                    }
                    _ => continue,
                }
                model.settle();
                let expected = model.shown.map(|at| copy_of(&cache, NAMES[at])).unwrap_or_default();
                prop_assert_eq!(tab_url(&hub), expected, "after {:?}", step);
            }
        }
    }
}

#[test]
fn what_the_window_keeps_out_of_the_sidebar_follows_what_runs() {
    let (hub, _) = hub("unlisted");
    let changes = Rc::new(Cell::new(0));
    let seen = changes.clone();
    on_running_changed(&hub.engine, move |_| seen.set(seen.get() + 1));
    let moved = Rc::new(Cell::new(0));
    let seen = moved.clone();
    on_pages_changed(&hub.engine, move |_| seen.set(seen.get() + 1));
    assert!(
        keeps_unlisted(&hub.engine, "env-1", "reviews"),
        "until its plugins are known"
    );

    plugins(&hub, "env-1", vec![reviews("r1")]);
    hub.advance(0);
    assert_eq!(changes.get(), 1);
    assert!(keeps_unlisted(&hub.engine, "env-1", "reviews"));
    assert!(
        !keeps_unlisted(&hub.engine, "env-1", "other"),
        "a plugin that is not running lists its threads"
    );

    let mut stopped = reviews("r1");
    stopped["status"] = json!("stopped");
    plugins(&hub, "env-1", vec![stopped]);
    hub.advance(0);
    assert_eq!(changes.get(), 2);
    assert!(!keeps_unlisted(&hub.engine, "env-1", "reviews"));
    assert!(moved.get() >= 1);
}

/// The titles the sidebar lists, in order.
fn sidebar_titles(hub: &Hub) -> Vec<String> {
    let state = hub.published("sidebar");
    ["pinned", "active", "snoozed", "settled"]
        .iter()
        .flat_map(|section| state[section].as_array().cloned().unwrap_or_default())
        .map(|row| row["title"].as_str().unwrap_or("").to_owned())
        .collect()
}

#[test]
fn the_sidebar_lists_a_plugins_unlisted_thread_once_it_stops() {
    let (hub, _) = hub("sidebar");
    const AT: &str = "2026-09-23T09:00:00Z";
    let thread = |id: &str, plugin: Json| {
        json!(["a", id, "thread", {"id": id, "projectId": "p1", "title": id,
            "createdAt": AT, "updatedAt": AT, "plugin": plugin}])
    };
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell", "mcs": [{"mc": "a", "online": true, "epoch": "e", "rev": 1,
                "environment": {"environmentId": "env-1", "label": "Laptop"}}],
            "rows": [
                ["a", "p1", "project", {"id": "p1", "title": "P", "workspaceRoot": "/w/p", "createdAt": AT, "updatedAt": AT}],
                thread("plain", Json::Null),
                thread("review", json!({"id": "reviews", "kind": "review", "listed": false})),
            ]}),
    );
    hub.advance(0);
    assert_eq!(
        sidebar_titles(&hub),
        ["plain"],
        "until its plugins are known"
    );
    plugins(&hub, "env-1", vec![reviews("r1")]);
    hub.advance(0);
    assert_eq!(sidebar_titles(&hub), ["plain"]);

    let mut stopped = reviews("r1");
    stopped["status"] = json!("stopped");
    plugins(&hub, "env-1", vec![stopped]);
    hub.advance(0);
    let mut titles = sidebar_titles(&hub);
    titles.sort();
    assert_eq!(titles, ["plain", "review"]);
}

#[test]
fn enabling_asks_for_the_permissions_first_and_only_then_enables() {
    let (hub, _) = hub("enable");
    plugins(
        &hub,
        "env-1",
        vec![json!({
            "id": "reviews", "name": "Reviews", "revision": "1", "status": "stopped", "runsCode": true,
            "permissions": [{"id": "threads.read", "label": "Read threads", "reason": "to list them"}, {"id": "net", "label": "Use the network"}],
        })],
    );
    hub.dispatch(
        "mcPlugins.enable",
        json!({"environment": "env-1", "id": "reviews"}),
    );
    assert_eq!(count(&hub, "plugins.enable"), 0);
    let question = hub.published("confirmation");
    assert_eq!(question["title"], "Enable \"Reviews\"?");
    assert_eq!(
        question["description"],
        "It asks to:\n• Read threads: to list them\n• Use the network\nIt runs its own code inside the MC on Laptop."
    );

    hub.dispatch(
        "confirmation.answer",
        json!({"requestId": question["requestId"], "accepted": false}),
    );
    assert_eq!(count(&hub, "plugins.enable"), 0);

    hub.dispatch(
        "mcPlugins.enable",
        json!({"environment": "env-1", "id": "reviews"}),
    );
    let question = hub.published("confirmation");
    hub.dispatch(
        "confirmation.answer",
        json!({"requestId": question["requestId"], "accepted": true}),
    );
    let (environment, input) = last(&hub, "plugins.enable");
    assert_eq!(environment, "env-1");
    assert_eq!(
        input,
        json!({"id": "reviews", "acceptPermissions": ["threads.read", "net"]})
    );
    hub.mc.answer(
        &hub.engine,
        "plugins.enable",
        Err(McError::new("Needs a restart")),
    );
    assert_eq!(toast_titles(&hub), ["The plugin could not be enabled"]);
}

#[test]
fn a_plugin_that_wants_nothing_is_enabled_at_once_and_the_rest_are_plain_calls() {
    let (hub, _) = hub("plain");
    plugins(
        &hub,
        "env-2",
        vec![json!({"id": "quiet", "revision": "1", "status": "stopped"})],
    );
    hub.dispatch(
        "mcPlugins.enable",
        json!({"environment": "env-2", "id": "quiet"}),
    );
    assert_eq!(
        last(&hub, "plugins.enable"),
        (
            "env-2".into(),
            json!({"id": "quiet", "acceptPermissions": []})
        )
    );
    hub.dispatch(
        "mcPlugins.disable",
        json!({"environment": "env-2", "id": "quiet"}),
    );
    assert_eq!(
        last(&hub, "plugins.disable"),
        ("env-2".into(), json!({"id": "quiet"}))
    );
    hub.dispatch(
        "mcPlugins.restart",
        json!({"environment": "env-2", "id": "quiet"}),
    );
    assert_eq!(
        last(&hub, "plugins.restart"),
        ("env-2".into(), json!({"id": "quiet"}))
    );
    hub.dispatch("mcPlugins.rescan", json!({"environment": "env-2"}));
    assert_eq!(last(&hub, "plugins.rescan"), ("env-2".into(), json!({})));
    hub.mc.answer(
        &hub.engine,
        "plugins.restart",
        Err(McError::new("Not running")),
    );
    assert_eq!(toast_titles(&hub), ["The plugin could not be restarted"]);

    // Without an environment and a plugin, nothing is asked.
    let asks = hub.mc.calls.borrow().len();
    hub.dispatch("mcPlugins.disable", json!({"id": "quiet"}));
    hub.dispatch("mcPlugins.rescan", json!({}));
    assert_eq!(hub.mc.calls.borrow().len(), asks);
}

// -- The singleton -----------------------------------------------------------

type Answers = Rc<RefCell<Vec<(i64, Json, String)>>>;
type Published = Rc<RefCell<Vec<(i64, Json)>>>;

fn listen(hub: &Hub) -> (ljos::prelude::ObjectId, Answers, Published) {
    let obj = hub
        .engine
        .singleton::<McPluginsObject>()
        .expect("McPlugins");
    let (answers, published) = (Answers::default(), Published::default());
    let seen = answers.clone();
    hub.engine
        .connect_by_name(obj, "answered", move |engine, args| {
            seen.borrow_mut().push((
                args[0].to_number() as i64,
                json::from_value(engine, &args[1]),
                engine.to_js_string(&args[2]).to_string(),
            ));
        })
        .unwrap();
    let seen = published.clone();
    hub.engine
        .connect_by_name(obj, "published", move |engine, args| {
            seen.borrow_mut().push((
                args[0].to_number() as i64,
                json::from_value(engine, &args[1]),
            ));
        })
        .unwrap();
    (obj, answers, published)
}

fn strings(hub: &Hub, parts: &[&str]) -> Vec<Value> {
    parts
        .iter()
        .map(|p| js_value(&hub.engine, &format!("'{p}'")))
        .collect()
}

#[test]
fn a_ui_part_calls_its_plugin_and_hears_the_answer_or_the_refusal() {
    let (hub, _) = hub("call");
    let (obj, answers, _) = listen(&hub);
    let mut args = strings(&hub, &["env-2", "reviews", "list"]);
    args.push(js_value(&hub.engine, "({ open: true })"));
    let first = call(&hub.engine, obj, "call", &args).to_number() as i64;
    assert_eq!(
        last(&hub, "plugins.call"),
        (
            "env-2".into(),
            json!({"id": "reviews", "method": "list", "input": {"open": true}})
        )
    );
    let second = call(&hub.engine, obj, "call", &args).to_number() as i64;
    assert_ne!(first, second);

    hub.mc
        .answer(&hub.engine, "plugins.call", Ok(json!({"rows": [1]})));
    hub.mc
        .answer(&hub.engine, "plugins.call", Err(McError::new("Nope")));
    let answers = answers.borrow();
    assert_eq!(answers[0], (first, json!({"rows": [1]}), String::new()));
    assert_eq!((answers[1].0, answers[1].2.as_str()), (second, "Nope"));

    let mut save = strings(&hub, &["env-1", "reviews"]);
    save.push(js_value(&hub.engine, "'not an object'"));
    call(&hub.engine, obj, "saveSettings", &save);
    assert_eq!(
        last(&hub, "plugins.saveSettings"),
        ("env-1".into(), json!({"id": "reviews", "settings": {}}))
    );
}

#[test]
fn watches_of_one_topic_share_a_subscription_and_a_later_one_is_given_the_last_value() {
    let (hub, _) = hub("watch");
    let (obj, _, published) = listen(&hub);
    let topic = |hub: &Hub| {
        hub.mc
            .subscriptions()
            .into_iter()
            .filter(|(_, s)| s["type"] == "plugin")
            .count()
    };
    let args = strings(&hub, &["env-1", "reviews", "open"]);
    let first = call(&hub.engine, obj, "watch", &args).to_number() as i64;
    assert_eq!(topic(&hub), 1);
    let shape = hub
        .mc
        .subscriptions()
        .into_iter()
        .map(|(_, s)| s)
        .find(|s| s["type"] == "plugin")
        .unwrap();
    assert_eq!(
        shape,
        json!({"type": "plugin", "environment": "env-1", "id": "reviews", "topic": "open"})
    );

    hub.mc.frame(
        &hub.engine,
        "plugin",
        "env-1",
        json!({"t": "plugin", "value": {"n": 1}}),
    );
    assert_eq!(*published.borrow(), [(first, json!({"n": 1}))]);

    let second = call(&hub.engine, obj, "watch", &args).to_number() as i64;
    assert_eq!(topic(&hub), 1);
    hub.advance(0);
    assert_eq!(
        published.borrow().last().unwrap(),
        &(second, json!({"n": 1}))
    );

    // Another topic is its own subscription.
    call(
        &hub.engine,
        obj,
        "watch",
        &strings(&hub, &["env-1", "reviews", "closed"]),
    );
    assert_eq!(topic(&hub), 2);

    call(
        &hub.engine,
        obj,
        "unwatch",
        &[js_value(&hub.engine, &first.to_string())],
    );
    assert_eq!(topic(&hub), 2, "one still follows it");
    call(
        &hub.engine,
        obj,
        "unwatch",
        &[js_value(&hub.engine, &second.to_string())],
    );
    assert_eq!(topic(&hub), 1);
    // Unwatching what is not watched is nothing.
    call(
        &hub.engine,
        obj,
        "unwatch",
        &[js_value(&hub.engine, &second.to_string())],
    );
}
