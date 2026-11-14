//! The app's preview automation host and the browser's pages: each page
//! showing a thread's tab is the agent's to drive, whatever order its tab
//! and its previews come in.

mod common;

use std::rc::Rc;

use common::{Scene, shell};
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
    // TODO(hal-c2/ljos-ui#438): the pinned Ljós runs the page's binding
    // only when it is read; drop this read once the pin is past c9d718aad.
    for (_, page) in hal_c2_shell::browser::pages(&engine) {
        engine.read_by_name(page, "previews");
    }
    scene.settle();
    assert!(
        host.has_page("tab-1"),
        "the page is the agent's once it has a thread"
    );
}
