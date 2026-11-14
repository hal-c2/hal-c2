//! `plugins`: this device's QML plugins, which are turned off, and where a
//! downloaded one came from (PluginController.cpp, features/plugins/).

use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;

use hal_c2_shell::Launch;
use hal_c2_shell::controllers::plugin::{Download, MAX_PLUGIN_BYTES, set_fetcher};
use hal_c2_shell::json::Json;
use serde_json::json;

use crate::Hub;

const URL: &str = "https://plugins.example/tools/hello.qml";

fn config_dir(test: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join("hub-plugin")
        .join(test);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("plugins")).unwrap();
    dir
}

fn hub(dir: &Path) -> Hub {
    Hub::with(Launch {
        config_dir: Some(dir.to_path_buf()),
        ..Launch::default()
    })
}

/// The downloads asked for and not answered yet.
type Pending = Rc<RefCell<Vec<(String, Download)>>>;

fn fetcher(hub: &Hub) -> Pending {
    let pending = Pending::default();
    let asked = pending.clone();
    set_fetcher(
        &hub.engine,
        Rc::new(move |_, url, done| asked.borrow_mut().push((url.to_owned(), done))),
    );
    pending
}

fn answer(hub: &Hub, pending: &Pending, result: Result<Vec<u8>, String>) {
    let (_, done) = pending.borrow_mut().remove(0);
    done(&hub.engine, result);
}

fn state(hub: &Hub) -> Json {
    hub.published("plugins")
}

fn files(hub: &Hub) -> Vec<String> {
    state(hub)["files"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| {
            Path::new(f["file"].as_str().unwrap())
                .file_name()
                .unwrap()
                .to_string_lossy()
                .into_owned()
        })
        .collect()
}

fn toast_titles(hub: &Hub) -> Vec<String> {
    hub.published("toasts")["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["title"].as_str().unwrap().to_owned())
        .collect()
}

fn answer_question(hub: &Hub, accepted: bool) {
    let request = hub.published("confirmation")["requestId"].clone();
    hub.dispatch(
        "confirmation.answer",
        json!({"requestId": request, "accepted": accepted}),
    );
}

/// What the registry says of the plugins it loaded from `files`.
fn loaded(hub: &Hub, dir: &Path, plugins: &[(&str, &str)], problems: &[(&str, &str, &str)]) {
    let at = |file: &str| {
        dir.join("plugins")
            .join(file)
            .to_string_lossy()
            .into_owned()
    };
    hub.dispatch(
        "plugins.report",
        json!({
            "plugins": plugins.iter().map(|(id, file)| json!({"id": id, "file": at(file)})).collect::<Vec<_>>(),
            "problems": problems.iter().map(|(id, file, message)| json!({"id": id, "file": at(file), "message": message})).collect::<Vec<_>>(),
        }),
    );
}

#[test]
fn the_plugin_files_are_listed_with_their_source_and_revision() {
    let dir = config_dir("listed");
    std::fs::write(dir.join("plugins/a.qml"), "Plugin { id: \"a\" }").unwrap();
    std::fs::write(dir.join("plugins/notes.txt"), "not a plugin").unwrap();
    let hub = hub(&dir);
    let published = state(&hub);
    assert_eq!(files(&hub), ["a.qml"]);
    assert_eq!(published["files"][0]["source"], "Plugin { id: \"a\" }");
    assert_eq!(
        published["dir"],
        dir.join("plugins").to_string_lossy().as_ref()
    );
    let first = published["files"][0]["revision"].clone();

    // A changed file is a new revision.
    std::fs::write(dir.join("plugins/a.qml"), "Plugin { id: \"a\"; order: 2 }").unwrap();
    hub.with_controller::<hal_c2_shell::controllers::plugin::Plugin, _>(|p, e| p.scan(e));
    assert_ne!(state(&hub)["files"][0]["revision"], first);
}

#[test]
fn a_plugin_turned_off_stays_off_across_restarts_until_turned_on() {
    let dir = config_dir("disabled");
    std::fs::write(dir.join("plugins/a.qml"), "Plugin { id: \"a\" }").unwrap();
    std::fs::write(dir.join("plugins/b.qml"), "Plugin { id: \"b\" }").unwrap();
    let hub1 = hub(&dir);
    loaded(&hub1, &dir, &[("a", "a.qml"), ("b", "b.qml")], &[]);
    hub1.dispatch("plugins.disable", json!({"id": "a"}));
    assert_eq!(files(&hub1), ["b.qml"]);
    assert_eq!(state(&hub1)["disabled"][0]["id"], "a");

    let hub2 = hub(&dir);
    assert_eq!(files(&hub2), ["b.qml"]);
    assert_eq!(state(&hub2)["disabled"][0]["id"], "a");
    hub2.dispatch("plugins.enable", json!({"id": "a"}));
    assert_eq!(files(&hub2), ["a.qml", "b.qml"]);
    assert_eq!(state(&hub2)["disabled"], json!([]));
    // Turning on what is not off changes nothing.
    hub2.dispatch("plugins.enable", json!({"id": "a"}));
    assert_eq!(files(&hub2), ["a.qml", "b.qml"]);
}

#[test]
fn an_installed_plugin_asks_first_then_downloads_and_says_it_loaded() {
    let dir = config_dir("install");
    let hub = hub(&dir);
    let pending = fetcher(&hub);
    hub.dispatch("plugins.install", json!({"url": URL}));
    let question = hub.published("confirmation");
    assert_eq!(question["title"], "Load this unsigned plugin?");
    assert_eq!(question["confirmLabel"], "Load plugin");
    assert_eq!(question["destructive"], true);
    assert!(
        pending.borrow().is_empty(),
        "nothing is fetched before the answer"
    );

    answer_question(&hub, true);
    assert_eq!(pending.borrow()[0].0, URL);
    answer(&hub, &pending, Ok(b"Plugin { id: \"hello\" }".to_vec()));
    assert_eq!(files(&hub), ["hello.qml"]);
    let records: Json =
        serde_json::from_slice(&std::fs::read(dir.join("plugins.json")).unwrap()).unwrap();
    let file = dir.join("plugins/hello.qml").to_string_lossy().into_owned();
    assert_eq!(records["sources"][&file], URL);

    loaded(&hub, &dir, &[("hello", "hello.qml")], &[]);
    assert_eq!(toast_titles(&hub), ["Plugin \"hello\" loaded."]);
    assert_eq!(state(&hub)["items"][0]["url"], URL);
}

#[test]
fn a_download_that_is_no_plugin_is_removed_and_says_why() {
    let dir = config_dir("broken");
    let hub = hub(&dir);
    let pending = fetcher(&hub);
    hub.dispatch("plugins.install", json!({"url": URL}));
    answer_question(&hub, true);
    answer(&hub, &pending, Ok(b"Item {}".to_vec()));
    assert_eq!(files(&hub), ["hello.qml"]);
    loaded(
        &hub,
        &dir,
        &[],
        &[("", "hello.qml", "it declares no Plugin")],
    );
    let toasts = hub.published("toasts");
    assert_eq!(
        toasts["items"][0]["title"],
        "The plugin could not be loaded"
    );
    assert_eq!(toasts["items"][0]["description"], "it declares no Plugin");
    assert!(files(&hub).is_empty());
    assert!(!dir.join("plugins/hello.qml").exists());
    assert_eq!(state(&hub)["failed"], json!([]));
}

#[test]
fn a_declined_question_downloads_nothing() {
    let dir = config_dir("declined");
    let hub = hub(&dir);
    let pending = fetcher(&hub);
    hub.dispatch("plugins.install", json!({"url": URL}));
    answer_question(&hub, false);
    assert!(pending.borrow().is_empty());
    assert_eq!(toast_titles(&hub), ["Nothing was loaded."]);
}

#[test]
fn only_an_http_address_of_a_qml_file_is_installed() {
    let dir = config_dir("bad-urls");
    let hub = hub(&dir);
    let pending = fetcher(&hub);
    for url in [
        "ftp://x.example/a.qml",
        "https://x.example/a.js",
        "nonsense",
        "",
    ] {
        hub.dispatch("plugins.install", json!({"url": url}));
        assert_eq!(hub.published("confirmation"), Json::Null, "{url}");
    }
    assert_eq!(
        toast_titles(&hub)[0],
        "A plugin URL is an http(s) address of a .qml file."
    );
    assert!(pending.borrow().is_empty());
}

#[test]
fn a_file_of_another_origin_is_not_overwritten() {
    let dir = config_dir("clash");
    std::fs::write(dir.join("plugins/hello.qml"), "Plugin { id: \"mine\" }").unwrap();
    let hub = hub(&dir);
    hub.dispatch("plugins.install", json!({"url": URL}));
    assert_eq!(hub.published("confirmation"), Json::Null);
    assert_eq!(
        toast_titles(&hub)[0],
        "A plugin file named hello.qml is already installed."
    );
}

#[test]
fn downloads_that_fail_or_are_unfit_keep_nothing() {
    let dir = config_dir("unfit");
    let hub = hub(&dir);
    let pending = fetcher(&hub);
    let attempt = |result: Result<Vec<u8>, String>| {
        hub.dispatch("plugins.install", json!({"url": URL}));
        answer_question(&hub, true);
        answer(&hub, &pending, result);
    };
    attempt(Err("The server answered 404.".into()));
    attempt(Ok(b"  \n".to_vec()));
    attempt(Ok(vec![b'x'; MAX_PLUGIN_BYTES + 1]));
    let toasts = hub.published("toasts");
    let described: Vec<&str> = toasts["items"]
        .as_array()
        .unwrap()
        .iter()
        .rev()
        .map(|i| i["description"].as_str().unwrap())
        .collect();
    assert_eq!(
        described,
        [
            "The server answered 404.",
            "hello.qml is empty.",
            "hello.qml is too large."
        ]
    );
    assert!(files(&hub).is_empty());
}

#[test]
fn removing_a_plugin_asks_and_deletes_its_file() {
    let dir = config_dir("remove");
    std::fs::write(dir.join("plugins/a.qml"), "Plugin { id: \"a\" }").unwrap();
    let hub = hub(&dir);
    loaded(&hub, &dir, &[("a", "a.qml")], &[]);
    hub.dispatch("plugins.remove", json!({"id": "a"}));
    let question = hub.published("confirmation");
    assert_eq!(question["title"], "Remove the plugin \"a\"?");
    assert_eq!(question["description"], "This deletes a.qml.");
    assert!(dir.join("plugins/a.qml").exists());
    answer_question(&hub, true);
    assert!(!dir.join("plugins/a.qml").exists());
    assert!(files(&hub).is_empty());
}
