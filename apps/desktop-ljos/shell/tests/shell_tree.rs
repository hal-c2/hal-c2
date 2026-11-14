//! `HalC2.Shell` as one module of native and QML types, the real bricks
//! loading under DefaultShell, and the code build.rs compiled from them.

mod common;

use std::path::Path;
use std::rc::Rc;

use common::{shell_with, text};
use hal_c2_shell::Launch;
use hal_c2_shell::mc::Disconnected;
use hal_c2_shell::qml::{self, Roots};
use ljos::dev::Severity;
use ljos::render::{Fonts, Picture, set_fonts};
use ljos::{App, ComponentSource as _};

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
    let compiled = qml::compile(&Roots::checkout()).expect("the roots are there");
    let errors: Vec<String> = compiled
        .diagnostics
        .iter()
        .filter(|d| d.severity == Severity::Error)
        .map(ToString::to_string)
        .collect();
    assert!(
        errors.is_empty(),
        "every QML file compiles:\n{}",
        errors.join("\n")
    );
    let source = compiled.source;
    let shell_window = source.url("HalC2/Bricks/ShellWindow");
    set_fonts(Fonts::Bundled);
    let engine = App::new("test")
        .register(hal_c2_shell::register)
        .source(source)
        .build_engine();
    let picture = Picture::new(640, 400).settle(200);
    picture.install(&engine);
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
    let png = picture.png(&engine, root).expect("a picture");
    assert_eq!(&png[..8], b"\x89PNG\r\n\x1a\n");
    // The bricks run the code build.rs compiled from them, which agrees
    // with the dynamic tiers (the cross-check is on in a debug build).
    assert_eq!(engine.aot_file(&shell_window), Some(true));
    let stats = engine.aot_stats();
    assert!(stats.runs > 0, "{stats:?}");
    let differ: Vec<String> = engine
        .take_warnings()
        .into_iter()
        .filter(|w| w.contains("compiled code") && !same_value(w))
        .collect();
    assert!(differ.is_empty(), "{stats:?}\n{}", differ.join("\n"));
}

/// The ljostypes.json build.rs compiles against says what `register`
/// registers. `LJOS_TYPES=write cargo test -p hal_c2_shell --test shell_tree`
/// writes it.
#[test]
fn the_type_dump_file_is_current() {
    let file = Path::new(env!("CARGO_MANIFEST_DIR")).join("ljostypes.json");
    ljos::types::check_file(&file, hal_c2_shell::register).unwrap_or_else(|e| panic!("{e}"));
}

/// Whether a cross-check warning gives the same value for both sides: one
/// that differs only in what was read. Compiled code does not track a read
/// of a readonly constant, which the dynamic tiers do, and the check counts
/// that as a mismatch; the binding is right, as the constant cannot change.
fn same_value(warning: &str) -> bool {
    warning
        .split_once("compiled gave ")
        .and_then(|(_, rest)| rest.split_once("; dynamic gave "))
        .is_some_and(|(compiled, dynamic)| dynamic.starts_with(&format!("{compiled};")))
}
