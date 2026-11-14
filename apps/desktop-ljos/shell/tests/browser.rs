//! `Browser`, the singleton BrowserPanel keeps its layout on this device in.

mod common;

use std::rc::Rc;
use std::time::Duration;

use common::{call, number, shell};
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::mc::Disconnected;

const MAIN: &str = "import QtQuick\nimport HalC2.Shell\nItem {\n    readonly property real share: Browser.devToolsShare\n    function again() {\n        Browser.devToolsShare = Browser.devToolsShare;\n        Browser.devicesPresetIds = Browser.devicesPresetIds;\n        Browser.devToolsDock = Browser.devToolsDock;\n        Browser.devicesView = Browser.devicesView;\n    }\n    function drag() { Browser.devToolsShare = 0.6 }\n}\n";

/// The panel writing back what it read is not a write: a device with
/// nowhere to save toasted each one, the toast laid the panel out again and
/// the panel wrote again, and the shell never settled.
#[test]
fn writing_back_the_layout_the_device_has_saves_nothing() {
    let (engine, root) = shell(MAIN, Rc::new(Disconnected::default()));
    engine.advance_timers(engine.now() + Duration::from_millis(1));
    assert_eq!(number(&engine, root, "share"), 0.4);

    call(&engine, root, "again", &[]);
    engine.advance_timers(engine.now() + Duration::from_millis(1));
    assert_eq!(Settings::of(&engine).device_error(), "");

    // A layout the user changed is written; here it cannot be saved, and
    // goes back to what the device has.
    call(&engine, root, "drag", &[]);
    assert_eq!(number(&engine, root, "share"), 0.6);
    engine.advance_timers(engine.now() + Duration::from_millis(1));
    assert_eq!(number(&engine, root, "share"), 0.4);
    assert_ne!(Settings::of(&engine).device_error(), "");
}
