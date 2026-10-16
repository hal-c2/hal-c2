//! `HalC2.Shell` as one module of native and QML types, and the real
//! bricks loading under DefaultShell.

mod common;

use std::rc::Rc;

use common::{shell_with, text};
use hal_c2_shell::mc::Disconnected;
use hal_c2_shell::qml::{self, Roots};
use hal_c2_shell::{Launch, render};
use ljos::App;

#[test]
fn native_and_qml_singletons_share_the_module() {
    let files = [
        (
            "HalC2/Shell/Palette",
            "pragma Singleton\nimport QtQuick\nimport HalC2.Shell\nQtObject { readonly property string kind: Shell.state.route.kind }\n",
        ),
        (
            "Main",
            "import QtQuick\nimport HalC2.Shell\nItem { readonly property string seen: Palette.kind + \"/\" + Runtime.appVersion }\n",
        ),
    ];
    let qmldirs = [(
        "HalC2/Shell",
        "module HalC2.Shell\nsingleton Palette 1.0 Palette.qml\n",
    )];
    let (engine, root) = shell_with(&files, &qmldirs, Rc::new(Disconnected::default()));
    let seen = text(&engine, root, "seen");
    assert_eq!(seen, format!("home/{}", env!("CARGO_PKG_VERSION")));
}

#[test]
fn the_desktop_shell_loads_from_the_checkout() {
    let loaded = qml::load(&Roots::checkout()).expect("the QML loads");
    // The native types not ported yet (Terminal, DeviceScreen,
    // LocalFolderModel) fail their files only.
    assert!(
        loaded.compiled * 10 >= loaded.files * 9,
        "{} of {}: {:?}",
        loaded.compiled,
        loaded.files,
        loaded.errors
    );
    let engine = App::new("test")
        .register(hal_c2_shell::register)
        .source(loaded.source)
        .build_engine();
    let clock = render::prepare(&engine);
    let mc = Rc::new(Disconnected::default());
    hal_c2_shell::start(&engine, &Launch::default(), mc.clone());
    hal_c2_shell::bridge::Bridge::of(&engine).dispatch(
        &engine,
        "usage.open",
        serde_json::Value::Null,
    );
    let root = engine
        .create_from_url("Main", None, Vec::new())
        .expect("Main is made");
    mc.deliver(&engine);
    let png = render::picture(&engine, &clock, root, (640, 400), 200).expect("a picture");
    assert_eq!(&png[..8], b"\x89PNG\r\n\x1a\n");
}
