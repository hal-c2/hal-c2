//! The plugins' QML draws its controls with the HalC2 bricks, so a plugin's
//! pages look and behave like the app's own. A stock QtQuick.Controls widget
//! that has a Shell brick takes the system's colours instead of the theme's;
//! this fails on the first one a plugin's QML (outside its tests) declares.

use std::fs;
use std::path::{Path, PathBuf};

/// Each stock control with a brick, and the brick to use instead.
const BRICKS: &[(&str, &str)] = &[
    ("Button", "ShellButton"),
    ("ToolButton", "ShellButton"),
    ("RoundButton", "ShellButton"),
    ("Switch", "ShellSwitch"),
    ("CheckBox", "ShellCheckBox"),
    ("RadioButton", "ShellChoice"),
    ("TextField", "ShellTextField"),
    ("TextArea", "ShellTextArea"),
    ("ComboBox", "ShellComboBox"),
    ("SpinBox", "ShellSpinBox"),
    ("Menu", "ShellMenu"),
    ("MenuItem", "ShellMenuItem"),
    ("MenuSeparator", "ShellMenuSeparator"),
    ("ToolTip", "ShellToolTip"),
    ("Popup", "ShellPopover"),
];

fn qml_files(dir: &Path, found: &mut Vec<PathBuf>) {
    for entry in fs::read_dir(dir).unwrap_or_else(|e| panic!("{}: {e}", dir.display())) {
        let path = entry.unwrap().path();
        if path.is_dir() {
            if path.file_name().is_some_and(|name| name != "test") {
                qml_files(&path, found);
            }
        } else if path.extension().is_some_and(|ext| ext == "qml") {
            found.push(path);
        }
    }
}

/// The type a line declares an object of, as in `Switch {`, `delegate: Switch {`,
/// `component Toggle: Switch {`, `property Component row: Switch {` or
/// `Controls.Switch {`; never an attached property (`ToolTip.text`).
fn declared(line: &str) -> Option<&str> {
    let line = line.trim_start();
    let line = [
        "component ",
        "property ",
        "readonly property ",
        "required property ",
        "default property ",
    ]
    .iter()
    .find_map(|prefix| line.strip_prefix(prefix))
    .map_or(line, |rest| rest.split_once(':').map_or(rest, |(_, ty)| ty));
    let line = match line.split_once(':') {
        Some((property, rest)) if property.chars().all(|c| c.is_alphanumeric() || c == '.') => rest,
        _ => line,
    };
    let line = line.trim_start();
    let end = line
        .find(|c: char| !c.is_alphanumeric() && c != '_' && c != '.')
        .unwrap_or(line.len());
    let (name, rest) = line.split_at(end);
    // A type named through its module's qualifier is still that type.
    let name = name.rsplit('.').next().unwrap_or(name);
    rest.trim_start().starts_with('{').then_some(name)
}

#[test]
fn plugin_qml_uses_the_bricks() {
    let plugins = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../plugins");
    let mut files = Vec::new();
    qml_files(&plugins, &mut files);
    assert!(
        !files.is_empty(),
        "no plugin QML under {}",
        plugins.display()
    );
    let mut stock = Vec::new();
    for file in &files {
        let text = fs::read_to_string(file).unwrap();
        for (number, line) in text.lines().enumerate() {
            if let Some(&(raw, brick)) =
                declared(line).and_then(|name| BRICKS.iter().find(|(raw, _)| *raw == name))
            {
                let file = file.strip_prefix(&plugins).unwrap_or(file).display();
                stock.push(format!("plugins/{file}:{}: {raw}, use {brick}", number + 1));
            }
        }
    }
    assert!(
        stock.is_empty(),
        "plugin QML uses stock controls that have bricks:\n{}",
        stock.join("\n")
    );
}

#[test]
fn a_declaration_is_told_from_an_attached_property() {
    assert_eq!(declared("    Switch {"), Some("Switch"));
    assert_eq!(declared("        delegate: TextField {"), Some("TextField"));
    assert_eq!(declared("    component Area: TextArea {"), Some("TextArea"));
    assert_eq!(declared("    ToolTip.text: qsTr(\"Open\")"), None);
    assert_eq!(declared("        ShellSwitch {"), Some("ShellSwitch"));
    assert_eq!(declared("    text: \"Switch {\""), None);
    assert_eq!(declared("    Controls.Switch {"), Some("Switch"));
    assert_eq!(
        declared("    property Component row: Switch {"),
        Some("Switch")
    );
    assert_eq!(
        declared("    readonly property var tip: ToolTip.text"),
        None
    );
}
