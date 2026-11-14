//! Settings → Open source licenses, driven as the page drives it: through
//! `Shell.dispatch` and `Shell.state`, over a manifest written for the test.

mod common;

use std::path::PathBuf;
use std::rc::Rc;

use common::shell;
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controllers::licenses::{SECTION, set_manifest_path};
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::{Disconnected, Mc};
use ljos::prelude::Engine;
use serde_json::json;

const EMPTY: &str = "import QtQuick\nItem {}\n";

fn published(engine: &Engine, key: &str) -> Json {
    Bridge::of(engine)
        .published(engine, key)
        .unwrap_or(Json::Null)
}

fn dispatch(engine: &Engine, action: &str, payload: Json) {
    Bridge::of(engine).dispatch(engine, action, payload);
}

fn licenses(engine: &Engine) -> Json {
    published(engine, "licenses")
}

/// Enough to tell the fields apart: no name, version or license holds
/// another field's query.
fn notices() -> Json {
    let entry = |kind: &str, name: &str, version: Option<&str>, license: &str, bundles: &[&str]| {
        let mut entry = json!({
            "kind": kind,
            "name": name,
            "license": license,
            "bundles": bundles,
            "noticeText": format!("{license} license text for {name}."),
        });
        if let Some(version) = version {
            entry["version"] = json!(version);
        }
        entry
    };
    json!([
        entry("package", "react", Some("19.1.0"), "MIT", &["web"]),
        entry(
            "package",
            "effect",
            Some("4.0.0-beta.1"),
            "MIT",
            &["web", "server"]
        ),
        entry(
            "package",
            "@effect/platform-node",
            Some("4.0.0-beta.1"),
            "MIT",
            &["server"]
        ),
        entry("package", "yaml", Some("2.8.1"), "ISC", &["web"]),
        entry("custom", "Qt", None, "LGPL-3.0-only", &["desktop-qt"]),
        entry(
            "custom",
            "MesloLGS NF",
            None,
            "Apache-2.0",
            &["android", "assets", "mobile"]
        ),
        entry(
            "custom",
            "agent-device",
            Some("0.21.7"),
            "MIT",
            &["device-tools"]
        ),
    ])
}

/// A directory of this test's own, with `manifest` in it.
fn manifest(test: &str, manifest: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(format!("licenses-{test}"));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("third-party-licenses.json");
    std::fs::write(&path, manifest).unwrap();
    path
}

fn good() -> String {
    json!({ "schemaVersion": 1, "entries": notices() }).to_string()
}

/// A shell with no MC, the manifest at `path`.
fn shell_over(path: &std::path::Path) -> Engine {
    let mc: Rc<dyn Mc> = Rc::new(Disconnected::default());
    let (engine, _) = shell(EMPTY, mc);
    set_manifest_path(&engine, path);
    engine
}

fn open_page(engine: &Engine) {
    dispatch(engine, "settings.navigate", json!({ "to": SECTION }));
}

fn names(engine: &Engine) -> Vec<String> {
    licenses(engine)["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["name"].as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn nothing_is_read_until_the_page_opens() {
    let path = manifest("lazy", &good());
    let engine = shell_over(&path);
    assert_eq!(licenses(&engine)["status"], "loading");
    assert_eq!(licenses(&engine)["total"], 0);
    dispatch(&engine, "settings.open", json!({}));
    assert_eq!(licenses(&engine)["status"], "loading");

    open_page(&engine);
    let page = licenses(&engine);
    assert_eq!(page["status"], "ready");
    assert_eq!(page["total"], 7);
    assert_eq!(page["message"], Json::Null);
}

#[test]
fn each_entry_names_its_version_license_and_where_it_is_used() {
    let path = manifest("fields", &good());
    let engine = shell_over(&path);
    open_page(&engine);
    let page = licenses(&engine);
    let entries = page["entries"].as_array().unwrap();
    let find = |name: &str| entries.iter().find(|e| e["name"] == name).unwrap().clone();

    let react = find("react");
    assert_eq!(react["key"], "package:react@19.1.0");
    assert_eq!(react["version"], "19.1.0");
    assert_eq!(react["license"], "MIT");
    assert_eq!(react["where"], "Web");
    assert_eq!(react["sourceUrl"], Json::Null);
    // No version is null, and the key still has its slot.
    assert_eq!(find("Qt")["version"], Json::Null);
    assert_eq!(find("Qt")["key"], "custom:Qt@");
    assert_eq!(find("Qt")["where"], "Qt desktop");
    assert_eq!(find("MesloLGS NF")["where"], "Android, Assets, Mobile");
    assert_eq!(find("agent-device")["where"], "Device tools");
    assert_eq!(find("effect")["where"], "Web, Server");
}

#[test]
fn a_bundle_without_a_label_shows_as_it_is() {
    let manifest = json!({ "schemaVersion": 1, "entries": [
        { "kind": "package", "name": "x", "license": "MIT", "bundles": ["mobile-qt", "tui"],
          "noticeText": "n", "sourceUrl": "https://example.test/x" },
    ]});
    let path = manifest_file("labels", &manifest);
    let engine = shell_over(&path);
    open_page(&engine);
    let entry = &licenses(&engine)["entries"][0];
    assert_eq!(entry["where"], "Qt mobile, tui");
    assert_eq!(entry["sourceUrl"], "https://example.test/x");
}

fn manifest_file(test: &str, json: &Json) -> PathBuf {
    manifest(test, &json.to_string())
}

#[test]
fn searching_narrows_by_name_license_or_component() {
    let path = manifest("search", &good());
    let engine = shell_over(&path);
    open_page(&engine);
    let search = |query: &str| {
        dispatch(&engine, "licenses.search", json!({ "query": query }));
        names(&engine)
    };
    assert_eq!(search("effect"), ["effect", "@effect/platform-node"]);
    assert_eq!(
        search("MIT"),
        ["react", "effect", "@effect/platform-node", "agent-device"]
    );
    assert_eq!(search("mobile"), ["MesloLGS NF"]);
    // Every word has to match, in any field, in any case.
    assert_eq!(search("  WEB   mit "), ["react", "effect"]);
    assert_eq!(
        search("4.0.0-beta.1 server"),
        ["effect", "@effect/platform-node"]
    );
    assert!(search("zzzz").is_empty());
    // The count of all of them is not narrowed.
    assert_eq!(licenses(&engine)["total"], 7);
    assert_eq!(licenses(&engine)["query"], "zzzz");
    assert_eq!(search("").len(), 7);
}

#[test]
fn opening_an_entry_shows_its_notice_and_the_same_one_again_closes_it() {
    let path = manifest("notice", &good());
    let engine = shell_over(&path);
    open_page(&engine);
    assert_eq!(licenses(&engine)["openKey"], Json::Null);

    dispatch(
        &engine,
        "licenses.open",
        json!({ "key": "package:react@19.1.0" }),
    );
    let page = licenses(&engine);
    assert_eq!(page["openKey"], "package:react@19.1.0");
    assert_eq!(page["noticeText"], "MIT license text for react.");

    // Another entry replaces it; a search that hides it hides its notice.
    dispatch(
        &engine,
        "licenses.open",
        json!({ "key": "package:yaml@2.8.1" }),
    );
    assert_eq!(
        licenses(&engine)["noticeText"],
        "ISC license text for yaml."
    );
    dispatch(&engine, "licenses.search", json!({ "query": "react" }));
    assert_eq!(licenses(&engine)["noticeText"], Json::Null);
    assert_eq!(licenses(&engine)["openKey"], Json::Null);
    dispatch(&engine, "licenses.search", json!({ "query": "" }));
    assert_eq!(licenses(&engine)["openKey"], "package:yaml@2.8.1");

    dispatch(
        &engine,
        "licenses.open",
        json!({ "key": "package:yaml@2.8.1" }),
    );
    assert_eq!(licenses(&engine)["openKey"], Json::Null);
}

#[test]
fn notices_that_fail_to_load_can_be_retried() {
    let path = manifest("retry", &good());
    std::fs::remove_file(&path).unwrap();
    let engine = shell_over(&path);
    open_page(&engine);
    let page = licenses(&engine);
    assert_eq!(page["status"], "error");
    assert_eq!(page["message"], "The license manifest could not load.");
    assert_eq!(page["total"], 0);

    std::fs::write(&path, good()).unwrap();
    dispatch(&engine, "licenses.retry", json!({}));
    let page = licenses(&engine);
    assert_eq!(page["status"], "ready");
    assert_eq!(page["message"], Json::Null);
    assert_eq!(page["total"], 7);
}

#[test]
fn a_page_that_failed_reads_again_when_it_is_opened_again() {
    let path = manifest("reopen", "");
    std::fs::remove_file(&path).unwrap();
    let engine = shell_over(&path);
    open_page(&engine);
    assert_eq!(licenses(&engine)["status"], "error");
    std::fs::write(&path, good()).unwrap();
    dispatch(
        &engine,
        "settings.navigate",
        json!({ "to": "/settings/general" }),
    );
    assert_eq!(licenses(&engine)["status"], "error");
    open_page(&engine);
    assert_eq!(licenses(&engine)["status"], "ready");

    // Once read it is not read again.
    std::fs::remove_file(&path).unwrap();
    dispatch(
        &engine,
        "settings.navigate",
        json!({ "to": "/settings/general" }),
    );
    open_page(&engine);
    assert_eq!(licenses(&engine)["status"], "ready");
    assert_eq!(licenses(&engine)["total"], 7);
}

#[test]
fn a_manifest_of_another_shape_is_refused_and_says_so() {
    let refused = |test: &str, manifest: Json| {
        let path = manifest_file(test, &manifest);
        let engine = shell_over(&path);
        open_page(&engine);
        let page = licenses(&engine);
        assert_eq!(page["status"], "error", "{test}");
        assert_eq!(page["total"], 0, "{test}");
        page["message"].as_str().unwrap().to_owned()
    };
    let unsupported = "The open-source license manifest has an unsupported format.";
    assert_eq!(
        refused("v2", json!({ "schemaVersion": 2, "entries": [] })),
        unsupported
    );
    assert_eq!(
        refused("no-entries", json!({ "schemaVersion": 1 })),
        unsupported
    );
    assert_eq!(
        refused("not-a-list", json!({ "schemaVersion": 1, "entries": {} })),
        unsupported
    );

    let ok = json!({ "kind": "package", "name": "a", "license": "MIT", "bundles": ["web"], "noticeText": "" });
    let broken = |field: &str| {
        let mut entry = ok.clone();
        entry.as_object_mut().unwrap().remove(field);
        entry
    };
    for field in ["name", "license", "bundles"] {
        assert_eq!(
            refused(
                field,
                json!({ "schemaVersion": 1, "entries": [ok, broken(field)] })
            ),
            "License entry 2 has an invalid shape.",
        );
    }
    let mut empty = ok.clone();
    empty["bundles"] = json!([]);
    assert_eq!(
        refused(
            "empty-bundles",
            json!({ "schemaVersion": 1, "entries": [empty] })
        ),
        "License entry 1 has an invalid shape.",
    );

    // Not JSON at all.
    let path = manifest("garbage", "<html>");
    let engine = shell_over(&path);
    open_page(&engine);
    assert_eq!(licenses(&engine)["message"], unsupported);
}

#[test]
fn other_actions_are_not_its_own() {
    let path = manifest("others", &good());
    let engine = shell_over(&path);
    dispatch(&engine, "licenses.nope", json!({}));
    dispatch(&engine, "settings.open", json!({}));
    assert_eq!(licenses(&engine)["status"], "loading");
}
