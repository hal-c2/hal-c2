//! The app's preview automation host and the browser's pages: each page
//! showing a thread's tab is the agent's to drive, whatever order its tab
//! and its previews come in.

mod common;

use std::rc::Rc;

use common::{Scene, compile, engine, read, shell, text};
use hal_c2_shell::controllers::preview_automation;
use hal_c2_shell::mc::Disconnected;
use hal_c2_shell::thread_view::previews::ThreadPreviews;
use ljos::prelude::Value;

const MAIN: &str = r#"
import QtQuick
import HalC2.Shell
Item {
    id: root
    property var previews: null
    BrowserPage { tabId: "tab-1"; previews: root.previews }
}
"#;

/// BrowserPanel's page took its tab id before its `source: Panel.previews`
/// resolved, and was never handed to the host: every agent's action in the
/// tab timed out unregistered.
#[test]
fn a_page_whose_previews_come_after_its_tab_is_driven() {
    let (engine, root) = shell(MAIN, Rc::new(Disconnected::default()));
    // What the page and the controllers left for later runs as frames go.
    let mut scene = Scene::new(&engine, root, (400.0, 300.0));
    scene.settle();
    let host = preview_automation::host(&engine).expect("the app has a browser host");
    assert!(!host.has_page("tab-1"), "a page with no thread is no one's");

    let previews = ThreadPreviews::create(
        &engine,
        None,
        Rc::new(Disconnected::default()),
        |_, _, _, _| {},
        |_, _| {},
    )
    .expect("the previews are made");
    ThreadPreviews::update(&engine, previews, |p| {
        p.set_thread("env-1", "thread-1", "mc-1")
    });
    engine
        .write_by_name(root, "previews", Value::Object(previews))
        .unwrap();
    scene.settle();
    assert!(
        host.has_page("tab-1"),
        "the page is the agent's once it has a thread"
    );
}

/// BrowserPanel's cue reads `PreviewAutomation.activity[tabId]`. Until an
/// agent acted in some tab, `activity` was undefined, so every preview tab
/// that opened threw a TypeError (#1644). It is an empty map from the start.
#[test]
fn the_activity_is_an_empty_map_before_any_agent_acts() {
    const CUE: &str = r#"
import QtQuick
import HalC2.Shell
Item {
    property string tabId: ""
    readonly property var entry: PreviewAutomation.activity[tabId] ?? null
    readonly property string kind: typeof PreviewAutomation.activity
    readonly property int tabs: Object.keys(PreviewAutomation.activity ?? {}).length
}
"#;
    let engine = engine(
        compile(&[("Main", CUE)], &[]),
        Rc::new(Disconnected::default()),
    );
    let root = hal_c2_shell::bridge::Bridge::main(&engine)
        .in_scope(&engine, || engine.create_from_url("Main", None, Vec::new()))
        .expect("Main is made");
    let mut scene = Scene::new(&engine, root, (400.0, 300.0));
    scene.settle();
    // A binding runs when it is first read, as BrowserPanel's cue is when
    // it is drawn: read it with an empty id first, then with the tab's
    // own, and only then take what it logged.
    let empty_id = matches!(read(&engine, root, "entry"), Value::Null);
    engine
        .write_by_name(root, "tabId", Value::from("browser:tab-1"))
        .unwrap();
    scene.settle();
    let tab_id = matches!(read(&engine, root, "entry"), Value::Null);
    let kind = text(&engine, root, "kind");
    let tabs = read(&engine, root, "tabs").to_number();
    let errors: Vec<String> = engine
        .take_warnings()
        .into_iter()
        .filter(|w| w.contains("activity") || w.contains("TypeError"))
        .collect();
    // All at once, so a failure shows what the cue read and what it logged.
    let seen = (kind, tabs, empty_id && tab_id, errors);
    assert_eq!(seen, ("object".to_owned(), 0.0, true, Vec::<String>::new()));
}
