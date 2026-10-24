//! `theme`: the look the shell resolves and publishes, and `Themes`
//! (ThemeController.cpp; tst_ThemeResolution.cpp and ThemeSteps.cpp,
//! features/navigation/appearance.feature, environment-themes.feature,
//! theme-editor.feature, features/desktop/native-settings.feature).

use std::cell::Cell;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::rc::Rc;
use std::sync::mpsc;

use hal_c2_shell::Launch;
use hal_c2_shell::commands::Commands;
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::theme::{
    Mode, Themes, ThemesObject, canonical_color, derive_palette,
};
use hal_c2_shell::json::{Json, from_value};
use ljos::item::Font;
use ljos::prelude::{ColorScheme, Engine, QmlValue, Value};
use serde_json::{Map, json};
use tempfile::TempDir;

use crate::Hub;
use crate::page::toasts;

/// A hub whose preferences and theme.json sit in a folder of their own, in a
/// light system.
fn hub() -> (Hub, TempDir) {
    let dir = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).unwrap();
    let hub = Hub::with(Launch {
        config_dir: Some(dir.path().to_owned()),
        ..Launch::default()
    });
    (hub, dir)
}

fn themes<R>(hub: &Hub, f: impl FnOnce(&mut Themes, &Engine) -> R) -> R {
    hub.with_controller::<Themes, R>(f)
}

/// The operating system turns dark or light.
fn system_dark(hub: &Hub, dark: bool) {
    ljos::testing::update_system_prefs(&hub.engine, |p| {
        p.color_scheme = if dark {
            ColorScheme::Dark
        } else {
            ColorScheme::Light
        }
    });
}

fn color(hub: &Hub, role: &str) -> String {
    hub.published("theme")["colors"][role]
        .as_str()
        .unwrap_or_default()
        .to_owned()
}

fn canvas(hub: &Hub) -> String {
    color(hub, "canvas")
}

fn resolved(hub: &Hub) -> String {
    themes(hub, |t, _| t.resolved_id())
}

fn save(hub: &Hub, device: Json) {
    let device = device.as_object().cloned().unwrap();
    assert!(Settings::of(&hub.engine).set_device_settings(&hub.engine, device));
}

fn publish(hub: &Hub, list: Vec<Json>) {
    Settings::of(&hub.engine).set_themes(&hub.engine, list);
}

fn theme(id: &str, appearance: &str, canvas: &str) -> Json {
    json!({"id": id, "label": id, "appearance": appearance, "colors": {"canvas": canvas}})
}

fn offered(hub: &Hub) -> Vec<Json> {
    themes(hub, |t, _| t.available())
}

fn offered_by_label(hub: &Hub, label: &str) -> Option<Json> {
    offered(hub).into_iter().find(|t| t["label"] == label)
}

fn swatch_of(hub: &Hub, id: &str) -> Vec<Json> {
    offered(hub)
        .into_iter()
        .find(|t| t["id"] == id)
        .and_then(|t| t["swatch"].as_array().cloned())
        .unwrap_or_default()
}

fn device(hub: &Hub) -> Map<String, Json> {
    Settings::of(&hub.engine).device()
}

/// This device's preferences in a folder that cannot be written: every
/// save after fails. Writable again when the guard goes.
struct Locked(std::path::PathBuf);

impl Drop for Locked {
    fn drop(&mut self) {
        let _ = std::fs::set_permissions(&self.0, std::fs::Permissions::from_mode(0o700));
    }
}

fn lock(hub: &Hub, dir: &Path) -> Locked {
    let locked = dir.join("locked");
    std::fs::create_dir_all(&locked).unwrap();
    let path = locked.join("preferences.json");
    std::fs::write(&path, serde_json::to_vec(&device(hub)).unwrap()).unwrap();
    Settings::of(&hub.engine).set_device_path(&hub.engine, Some(path));
    std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o500)).unwrap();
    Locked(locked)
}

// -- What is drawn -------------------------------------------------------------

/// A role no theme carries is drawn in its fallback, in light themes too (a
/// "popover" dialog stayed near-black): every role the bricks ask the palette
/// for by name comes with every theme, or is one a theme may add.
#[test]
fn bricks_paint_with_roles_every_theme_has() {
    // Drawn in the brick's own fallback unless a theme names them.
    let optional = [
        "projectForeground",
        "branchForeground",
        "sidebarActiveIndicator",
        "scrim",
    ];
    let (hub, _dir) = hub();
    let app = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../desktop-qt");
    let mut roles: Vec<(String, String)> = Vec::new();
    for dir in ["qml", "../mobile-qt/qml"] {
        let mut folders = vec![app.join(dir)];
        while let Some(folder) = folders.pop() {
            for entry in std::fs::read_dir(&folder).unwrap().flatten() {
                let path = entry.path();
                if path.is_dir() {
                    folders.push(path);
                } else if path.extension().is_some_and(|e| e == "qml") {
                    let text = std::fs::read_to_string(&path).unwrap();
                    for part in text.split("palette.color(\"").skip(1) {
                        let role: String = part
                            .chars()
                            .take_while(char::is_ascii_alphanumeric)
                            .collect();
                        let file = path.file_name().unwrap().to_string_lossy().into_owned();
                        roles.push((file, role));
                    }
                }
            }
        }
    }
    assert!(roles.len() > 100, "{}", roles.len());
    let mut unknown: Vec<String> = Vec::new();
    for dark in [false, true] {
        system_dark(&hub, dark);
        let colors = hub.published("theme")["colors"].clone();
        for (file, role) in &roles {
            let missing = colors.get(role).is_none() && !optional.contains(&role.as_str());
            let where_ = format!("{file}:{role}");
            if missing && !unknown.contains(&where_) {
                unknown.push(where_);
            }
        }
    }
    assert!(unknown.is_empty(), "{}", unknown.join(", "));
}

#[test]
fn nothing_chosen_is_the_standard_look() {
    let (hub, _dir) = hub();
    assert_eq!(hub.published("theme")["id"], "hal-c2");
    assert_eq!(canvas(&hub), "#fcfcfc");
    system_dark(&hub, true);
    assert_eq!(canvas(&hub), "#0a0a0a");
    // The roles the bricks paint outside theme files come with every theme.
    for role in ["success", "info"] {
        assert!(!color(&hub, role).is_empty(), "{role}");
    }
    // Every colour is one the palette reads.
    for (role, value) in hub.published("theme")["colors"].as_object().unwrap() {
        assert_eq!(
            canonical_color(value.as_str().unwrap()).as_deref(),
            value.as_str(),
            "{role}"
        );
    }
}

#[test]
fn the_look_follows_the_system_scheme_while_it_runs() {
    let (hub, _dir) = hub();
    assert_eq!(themes(&hub, |t, _| t.appearance()), "light");
    system_dark(&hub, true);
    assert_eq!(themes(&hub, |t, _| t.appearance()), "dark");
    assert_eq!(hub.published("theme")["appearance"], "dark");
    // A chosen mode no longer follows it.
    themes(&hub, |t, e| assert!(t.set_mode(e, Mode::Light)));
    system_dark(&hub, false);
    system_dark(&hub, true);
    assert_eq!(themes(&hub, |t, _| t.appearance()), "light");
    themes(&hub, |t, e| assert!(t.set_mode(e, Mode::System)));
    assert_eq!(themes(&hub, |t, _| t.appearance()), "dark");
    // The mode is this device's preference.
    assert_eq!(device(&hub)["appearance"], "system");
}

#[test]
fn menus_and_dialogs_are_nearly_opaque_by_default() {
    let (hub, _dir) = hub();
    assert_eq!(color(&hub, "surfaceOverlay"), "#fffffff5");
    system_dark(&hub, true);
    assert_eq!(color(&hub, "surfaceOverlay"), "#111111f5");
    // Fully solid at 100, and never under 40.
    let settings = Settings::of(&hub.engine);
    assert!(settings.write_device(&hub.engine, "glassOpacity", json!(100)));
    assert_eq!(color(&hub, "surfaceOverlay"), "#111111");
    assert!(settings.write_device(&hub.engine, "glassOpacity", json!(50)));
    assert_eq!(color(&hub, "surfaceOverlay"), "#11111180");
    assert!(settings.write_device(&hub.engine, "glassOpacity", json!(10)));
    assert_eq!(color(&hub, "surfaceOverlay"), "#11111166");
}

#[test]
fn the_appearance_rows_reach_the_published_theme() {
    let (hub, _dir) = hub();
    assert_eq!(color(&hub, "diffAdded"), "#22c55e");
    assert_eq!(color(&hub, "diffRemoved"), "#ef4444");
    let theme = hub.published("theme");
    assert_eq!(
        theme["fontSizes"],
        json!({"interface": 16, "prompt": 14, "code": 13, "terminal": 12})
    );
    assert_eq!(theme["fontPrompt"], "");
    assert_eq!(theme["fontTerminal"], "");
    let builtin_ui = theme["fontUi"].clone();
    assert!(!builtin_ui.as_str().unwrap().is_empty());

    let settings = Settings::of(&hub.engine);
    for (key, value) in [
        ("diffColorScheme", json!("blue-orange")),
        ("fontFamilySans", json!("  Inter  ")),
        ("fontFamilyCode", json!("Iosevka")),
        ("fontFamilyComposer", json!("Literata")),
        ("fontFamilyTerminal", json!("Hack")),
        ("fontSizeInterface", json!(18)),
        ("fontSizeTerminal", json!(0)),
    ] {
        assert!(settings.write_device(&hub.engine, key, value));
    }
    let theme = hub.published("theme");
    assert_eq!(theme["colors"]["diffAdded"], "#3b82f6");
    assert_eq!(theme["colors"]["diffRemoved"], "#f97316");
    assert_eq!(theme["fontUi"], "Inter");
    assert_eq!(theme["fontMono"], "Iosevka");
    assert_eq!(theme["fontPrompt"], "Literata");
    assert_eq!(theme["fontTerminal"], "Hack");
    // A size of 0 is the default's.
    assert_eq!(
        theme["fontSizes"],
        json!({"interface": 18, "prompt": 14, "code": 13, "terminal": 12})
    );
    // The interface font is the application's: the saved one, unless the
    // shell theme file names its own.
    assert_eq!(
        hal_c2_shell::theme::application_font_family(&hub.engine),
        "Inter"
    );
}

// ThemeStore::applyInterfaceFont (tst_ShellRuntime): the interface font is
// the application's while the app runs. What names no family takes it, what
// names its own keeps it, and a reset is the desktop's font again.
#[test]
fn the_interface_font_reaches_what_is_on_screen() {
    let (hub, _dir) = hub();
    let source = crate::common::compile(
        &[(
            "Probe",
            "import QtQuick\nimport QtQuick.Controls\nItem {\n\
             Label { id: label; font.pixelSize: 20 }\n\
             Button { id: button }\n\
             Label { id: code; font.family: \"monospace\" }\n\
             Text { id: plain }\n\
             property string label: label.font.family\n\
             property string plain: plain.font.family\n\
             property int labelSize: label.font.pixelSize\n\
             property string button: button.font.family\n\
             property string code: code.font.family\n}",
        )],
        &[],
    );
    let (root, _window) = hub.show(source, "Probe");
    let family = |name: &str| {
        hub.engine
            .to_js_string(&hub.engine.read_by_name(root, name))
            .to_string()
    };
    let desktop = family("label");
    let settings = Settings::of(&hub.engine);
    assert!(settings.write_device(&hub.engine, "fontFamilySans", json!("Literata")));
    hub.advance(0);
    assert_eq!(&*ljos::application_font(&hub.engine).family, "Literata");
    assert_eq!(family("label"), "Literata");
    assert_eq!(family("button"), "Literata");
    // A plain Text made before the change follows it too.
    assert_eq!(family("plain"), "Literata");
    assert_eq!(family("code"), "monospace");
    assert_eq!(hub.engine.read_by_name(root, "labelSize").to_number(), 20.0);

    assert!(settings.write_device(&hub.engine, "fontFamilySans", json!("")));
    hub.advance(0);
    assert_eq!(family("label"), desktop);
    assert_eq!(family("plain"), desktop);
}

#[test]
fn every_theme_offered_carries_its_swatch() {
    let (hub, _dir) = hub();
    let standard = |hub: &Hub| themes(hub, |t, _| t.available()).len();
    assert!(standard(&hub) > 3);
    let light = swatch_of(&hub, "grove");
    for theme in offered(&hub) {
        let swatch = theme["swatch"].as_array().unwrap();
        assert_eq!(swatch.len(), 3, "{theme}");
        for color in swatch {
            assert!(
                canonical_color(color.as_str().unwrap()).is_some(),
                "{theme}"
            );
        }
    }
    system_dark(&hub, true);
    assert_ne!(swatch_of(&hub, "grove"), light);
    // A theme without the appearance drawn shows the one it has.
    save(
        &hub,
        json!({"customThemes": [theme("mine", "light", "#010101")]}),
    );
    assert_eq!(swatch_of(&hub, "mine")[0], "#010101");
    let mine = offered(&hub)
        .into_iter()
        .find(|t| t["id"] == "mine")
        .unwrap();
    assert_eq!(mine["appearances"], json!(["light"]));
    assert_eq!(mine["source"], "custom");
}

#[test]
fn built_ins_win_their_ids() {
    let (hub, _dir) = hub();
    save(
        &hub,
        json!({"customThemes": [theme("grove", "light", "#010101")], "theme": "grove"}),
    );
    assert_eq!(resolved(&hub), "grove");
    assert_eq!(
        Some(canvas(&hub)),
        canonical_color("oklch(0.972369 0.005497 157.15)")
    );
}

/// A published theme may not take the standard look's id either: it would
/// offer a second "hal-c2" row beside the standard look.
#[test]
fn a_published_theme_cannot_take_the_standard_looks_id() {
    let (hub, _dir) = hub();
    let before = offered(&hub);
    publish(&hub, vec![theme("hal-c2", "dark", "#020202")]);
    assert_eq!(offered(&hub), before);
    assert_eq!(resolved(&hub), "hal-c2");
    publish(&hub, Vec::new());
}

#[test]
fn saved_themes_win_over_published_ones() {
    let (hub, _dir) = hub();
    publish(&hub, vec![theme("dusk", "light", "#020202")]);
    save(&hub, json!({"theme": "dusk"}));
    assert_eq!(canvas(&hub), "#020202");
    save(
        &hub,
        json!({"theme": "dusk", "customThemes": [theme("dusk", "light", "#030303")]}),
    );
    assert_eq!(canvas(&hub), "#030303");
    let dusks = offered(&hub).iter().filter(|t| t["id"] == "dusk").count();
    assert_eq!(dusks, 1);
    // No longer saved, the published one is drawn again; no longer
    // published either, the standard look.
    save(&hub, json!({"theme": "dusk"}));
    assert_eq!(canvas(&hub), "#020202");
    assert_eq!(
        offered(&hub).iter().find(|t| t["id"] == "dusk").unwrap()["source"],
        "environment"
    );
    publish(&hub, Vec::new());
    assert_eq!(resolved(&hub), "hal-c2");
}

#[test]
fn missing_roles_come_from_the_defaults() {
    let (hub, _dir) = hub();
    publish(&hub, vec![theme("dusk", "light", "#020202")]);
    save(&hub, json!({"theme": "dusk"}));
    assert!(color(&hub, "text").starts_with('#'));
    // The short form: a canvas and an accent paint the surfaces and accents.
    publish(
        &hub,
        vec![
            json!({"id": "dusk", "appearance": "light", "canvas": "#040404", "accent": "#ff0000"}),
        ],
    );
    assert_eq!(color(&hub, "sidebar"), "#040404");
    assert_eq!(color(&hub, "focus"), "#ff0000");
    // A name is its label when it has none.
    assert_eq!(offered_by_label(&hub, "dusk").unwrap()["id"], "dusk");
    // A theme with nothing drawable is not offered.
    publish(&hub, vec![theme("dusk", "light", "not a colour")]);
    assert_eq!(resolved(&hub), "hal-c2");
}

#[test]
fn halves_over_the_chosen_theme() {
    let (hub, _dir) = hub();
    save(
        &hub,
        json!({"theme": "iris", "themeHalves": {"dark": "ocean"}}),
    );
    assert_eq!(resolved(&hub), "iris");
    system_dark(&hub, true);
    assert_eq!(resolved(&hub), "ocean");
    assert_eq!(themes(&hub, |t, _| t.appearance()), "dark");
    // Choosing a whole theme drops the halves.
    themes(&hub, |t, e| assert!(t.choose(e, "grove")));
    assert_eq!(resolved(&hub), "grove");
    assert!(themes(&hub, |t, _| t.halves()).is_empty());
    // A half cleared goes, and with the last one the key.
    themes(&hub, |t, e| {
        assert!(t.choose_half(e, "light", "iris"));
        assert!(t.choose_half(e, "light", ""));
        assert!(!t.choose_half(e, "dusk", "iris"));
    });
    assert!(!device(&hub).contains_key("themeHalves"));
    // The standard look again.
    themes(&hub, |t, e| assert!(t.choose(e, "")));
    assert!(!device(&hub).contains_key("theme"));
    assert_eq!(resolved(&hub), "hal-c2");
}

#[test]
fn a_one_appearance_theme_keeps_its_appearance() {
    let (hub, _dir) = hub();
    save(
        &hub,
        json!({"customThemes": [theme("midnight", "dark", "#050505")], "theme": "grove"}),
    );
    // Chosen, it takes the dark half only.
    themes(&hub, |t, e| assert!(t.choose(e, "midnight")));
    assert_eq!(themes(&hub, |t, _| t.theme_id()), "grove");
    assert_eq!(themes(&hub, |t, _| t.halves())["dark"], "midnight");
    assert_eq!(resolved(&hub), "grove");
    system_dark(&hub, true);
    assert_eq!(canvas(&hub), "#050505");
    // As the whole choice (a file written elsewhere), it is drawn in its own
    // appearance.
    save(
        &hub,
        json!({"customThemes": [theme("midnight", "dark", "#050505")], "theme": "midnight",
               "appearance": "light"}),
    );
    assert_eq!(themes(&hub, |t, _| t.appearance()), "dark");
    assert_eq!(canvas(&hub), "#050505");
}

#[test]
fn restoring_defaults_is_all_or_nothing() {
    let (hub, dir) = hub();
    save(
        &hub,
        json!({"theme": "grove", "appearance": "dark", "themeHalves": {"light": "grove"},
               "timestampFormat": "24-hour"}),
    );
    let locked = lock(&hub, dir.path());
    assert!(!themes(&hub, |t, e| t.restore_defaults(e)));
    assert_eq!(themes(&hub, |t, _| t.theme_id()), "grove");
    assert_eq!(themes(&hub, |t, _| t.mode()), Mode::Dark);
    assert!(!themes(&hub, |t, _| t.halves()).is_empty());
    assert!(
        toasts(&hub)
            .iter()
            .any(|(title, _)| title == "Couldn’t restore theme settings")
    );
    // Nor is any other choice saved.
    assert!(!themes(&hub, |t, e| t.choose(e, "iris")));
    assert!(
        toasts(&hub)
            .iter()
            .any(|(title, _)| title == "Couldn't save theme selection")
    );
    drop(locked);
    assert!(themes(&hub, |t, e| t.restore_defaults(e)));
    assert_eq!(themes(&hub, |t, _| t.theme_id()), "");
    assert_eq!(themes(&hub, |t, _| t.mode()), Mode::System);
    assert!(themes(&hub, |t, _| t.halves()).is_empty());
    assert_eq!(device(&hub)["timestampFormat"], "24-hour");
}

// -- The appearance shortcut and the commands --------------------------------------

#[test]
fn the_appearance_shortcut_cycles_with_one_toast() {
    let (hub, _dir) = hub();
    let appearance_toasts = |hub: &Hub| {
        toasts(hub)
            .into_iter()
            .filter(|(title, _)| title.starts_with("Appearance: "))
            .map(|(title, _)| title)
            .collect::<Vec<_>>()
    };
    hub.dispatch("appearance.cycle", json!({}));
    assert_eq!(themes(&hub, |t, _| t.mode()), Mode::Light);
    assert_eq!(appearance_toasts(&hub), ["Appearance: Light"]);
    hub.dispatch("appearance.cycle", json!({}));
    assert_eq!(appearance_toasts(&hub), ["Appearance: Dark"]);
    hub.dispatch("appearance.cycle", json!({}));
    assert_eq!(themes(&hub, |t, _| t.mode()), Mode::System);
    assert_eq!(appearance_toasts(&hub), ["Appearance: System"]);
    // It goes on its own.
    hub.advance(1600);
    assert!(appearance_toasts(&hub).is_empty());
    // The palette's command is the same.
    assert!(Commands::of(&hub.engine).run(&hub.engine, "appearance.cycle"));
    assert_eq!(themes(&hub, |t, _| t.mode()), Mode::Light);
}

#[test]
fn the_palette_changes_the_theme_and_the_appearance() {
    let (hub, _dir) = hub();
    save(
        &hub,
        json!({"customThemes": [theme("midnight", "dark", "#050505")]}),
    );
    let commands = Commands::of(&hub.engine);
    let choices = commands.choices(&hub.engine, "theme.select");
    assert_eq!(choices[0].id, "theme:standard");
    assert_eq!(choices[0].title, "HAL-C2");
    assert!(choices[0].current);
    let grove = choices
        .iter()
        .find(|c| c.id == "theme:palette:grove")
        .unwrap();
    assert!(!grove.current);
    assert_eq!(grove.terms, ["theme", "appearance"]);
    let midnight = choices
        .iter()
        .find(|c| c.id == "theme:palette:midnight")
        .unwrap();
    assert_eq!(midnight.description, "For dark mode");
    (grove.run.clone().unwrap())(&hub.engine);
    assert_eq!(resolved(&hub), "grove");
    (midnight.run.clone().unwrap())(&hub.engine);
    assert_eq!(themes(&hub, |t, _| t.halves())["dark"], "midnight");
    let choices = commands.choices(&hub.engine, "theme.select");
    assert!(
        choices
            .iter()
            .find(|c| c.id == "theme:palette:grove")
            .unwrap()
            .current
    );

    let modes = commands.choices(&hub.engine, "appearance.select");
    let titles: Vec<&str> = modes.iter().map(|c| c.title.as_str()).collect();
    assert_eq!(titles, ["System", "Light", "Dark"]);
    assert!(modes[0].current);
    (modes[2].run.clone().unwrap())(&hub.engine);
    assert_eq!(themes(&hub, |t, _| t.mode()), Mode::Dark);
    assert!(commands.choices(&hub.engine, "appearance.select")[2].current);

    assert!(commands.run(&hub.engine, "themeEditor.toggle"));
    assert!(themes(&hub, |t, _| t.editor_open()));
    assert!(commands.run(&hub.engine, "themeEditor.toggle"));
    assert!(!themes(&hub, |t, _| t.editor_open()));
}

// -- This device's themes and the editor ----------------------------------------------

#[test]
fn a_new_theme_starts_from_the_one_drawn_and_saves_over_itself() {
    let (hub, _dir) = hub();
    themes(&hub, |t, e| assert!(t.choose(e, "grove")));
    let mut draft = themes(&hub, |t, e| t.draft(e, ""));
    // A built-in is a starting point, not saved over.
    assert_eq!(draft["id"], "");
    assert_eq!(draft["label"], "Grove");
    assert_eq!(draft["colors"]["canvas"], canvas(&hub));
    draft.insert("label".into(), json!("  Edited  "));
    draft["colors"]["canvas"] = json!("#203040");
    let id = themes(&hub, |t, e| t.save_custom(e, &draft));
    assert_eq!(id, "edited");
    assert_eq!(resolved(&hub), "edited");
    assert_eq!(canvas(&hub), "#203040");
    // Saved again, over itself.
    let mut again = themes(&hub, |t, e| t.draft(e, ""));
    assert_eq!(again["id"], "edited");
    again["colors"]["canvas"] = json!("Tomato");
    assert_eq!(themes(&hub, |t, e| t.save_custom(e, &again)), "edited");
    assert_eq!(canvas(&hub), "#ff6347");
    // A new one of the same name, beside it.
    again.insert("id".into(), json!(""));
    assert_eq!(themes(&hub, |t, e| t.save_custom(e, &again)), "edited-2");
    // Not without a name.
    again.insert("label".into(), json!("   "));
    assert_eq!(themes(&hub, |t, e| t.save_custom(e, &again)), "");
    // A name a built-in has gets a number.
    again.insert("label".into(), json!("Grove"));
    assert_eq!(themes(&hub, |t, e| t.save_custom(e, &again)), "grove-2");
}

#[test]
fn a_duplicate_is_an_editable_copy() {
    let (hub, _dir) = hub();
    let id = themes(&hub, |t, e| t.duplicate(e, "grove"));
    assert_eq!(id, "grove-copy");
    let copy = offered_by_label(&hub, "Grove copy").unwrap();
    assert_eq!(copy["source"], "custom");
    let original = themes(&hub, |t, e| t.draft(e, "grove"));
    let duplicate = themes(&hub, |t, e| t.draft(e, &id));
    assert_eq!(duplicate["colors"], original["colors"]);
    assert_eq!(themes(&hub, |t, e| t.duplicate(e, "no-such-theme")), "");
}

/// The standard look has no row of its own to copy from, so it has its own
/// duplicate: the copy is the standard look as drawn now, whatever is saved.
#[test]
fn the_standard_look_can_be_duplicated() {
    let (hub, _dir) = hub();
    let standard = themes(&hub, |t, e| t.draft(e, "hal-c2"))["colors"].clone();
    let id = themes(&hub, |t, e| t.duplicate_standard(e));
    assert_eq!(id, "hal-c2-copy");
    let copy = offered_by_label(&hub, "HAL-C2 copy").unwrap();
    assert_eq!(copy["source"], "custom");
    assert_eq!(themes(&hub, |t, e| t.draft(e, &id))["colors"], standard);
    // Saved themes are pinned to one appearance, so the copy is in use.
    assert_eq!(resolved(&hub), id);
}

/// In the appearance showing now.
#[test]
fn the_standard_looks_copy_is_in_the_appearance_showing() {
    let (hub, _dir) = hub();
    system_dark(&hub, true);
    let dark = themes(&hub, |t, e| t.draft(e, "hal-c2"));
    let id = themes(&hub, |t, e| t.duplicate_standard(e));
    assert_eq!(
        themes(&hub, |t, e| t.draft(e, &id))["colors"],
        dark["colors"]
    );
    assert_eq!(themes(&hub, |t, e| t.draft(e, &id))["appearance"], "dark");
}

/// A saved theme made before the standard look's id was kept from new ones
/// does not stand in for the standard look.
#[test]
fn a_saved_theme_with_the_standard_looks_id_does_not_stand_in_for_it() {
    let (hub, _dir) = hub();
    let imposter = json!({"id": "hal-c2", "label": "Imposter", "appearance": "dark",
                          "colors": {"canvas": "#112233", "accent": "#445566"}});
    save(&hub, json!({"customThemes": [imposter]}));
    let id = themes(&hub, |t, e| t.duplicate_standard(e));
    assert_eq!(id, "hal-c2-copy");
    let drawn = themes(&hub, |t, e| t.draft(e, &id));
    assert_ne!(drawn["colors"]["canvas"], "#112233");
    assert!(offered_by_label(&hub, "Imposter").is_some());
    // A new theme named for it takes another id.
    let mut draft = themes(&hub, |t, e| t.draft(e, ""));
    draft.insert("id".into(), json!(""));
    draft.insert("label".into(), json!("HAL-C2"));
    assert_eq!(themes(&hub, |t, e| t.save_custom(e, &draft)), "hal-c2-2");
}

/// draft("") starts from the theme actually drawn: a single-appearance
/// theme chosen as a half (no whole theme set) is that draft, not the
/// standard look.
#[test]
fn a_draft_with_no_id_starts_from_the_drawn_half() {
    let (hub, _dir) = hub();
    save(
        &hub,
        json!({"customThemes": [theme("midnight", "dark", "#050505")]}),
    );
    themes(&hub, |t, e| assert!(t.choose(e, "midnight")));
    assert_eq!(themes(&hub, |t, _| t.theme_id()), "");
    system_dark(&hub, true);
    assert_eq!(resolved(&hub), "midnight");
    let drawn = themes(&hub, |t, e| t.draft(e, ""));
    assert_eq!(drawn["label"], "midnight");
    assert_eq!(drawn["colors"]["canvas"], "#050505");
    // In the other appearance nothing is chosen, so the standard look is
    // drawn and drafted.
    system_dark(&hub, false);
    assert_eq!(themes(&hub, |t, e| t.draft(e, ""))["label"], "HAL-C2");
}

/// A choice that no longer resolves draws the standard look, so that is
/// what is drafted -- not a legacy saved theme that holds the standard id.
#[test]
fn a_draft_with_a_stale_choice_starts_from_the_standard_look() {
    let (hub, _dir) = hub();
    let legacy = theme("hal-c2", "dark", "#050505");
    save(
        &hub,
        json!({"customThemes": [legacy.clone()], "theme": "gone"}),
    );
    assert_eq!(resolved(&hub), "hal-c2");
    let drawn = themes(&hub, |t, e| t.draft(e, ""));
    assert_eq!(drawn["id"], "");
    assert_eq!(drawn["label"], "HAL-C2");
    // Chosen on purpose, the legacy theme is drafted.
    save(&hub, json!({"customThemes": [legacy], "theme": "hal-c2"}));
    assert_eq!(themes(&hub, |t, e| t.draft(e, ""))["id"], "hal-c2");
}

#[test]
fn removing_a_theme_asks_first_and_forgets_its_choices() {
    let (hub, dir) = hub();
    save(
        &hub,
        json!({"customThemes": [theme("one", "light", "#010101"), theme("two", "dark", "#020202"),
                                theme("three", "light", "#030303")],
               "theme": "one", "themeHalves": {"dark": "two"}}),
    );
    // Built-ins are not this device's to remove.
    themes(&hub, |t, e| t.request_remove(e, "grove"));
    assert_eq!(hub.published("confirmation"), json!(null));
    themes(&hub, |t, e| t.request_remove(e, "one"));
    let asked = hub.published("confirmation");
    assert_eq!(asked["title"], "Remove “one”?");
    assert_eq!(asked["description"], "This device will no longer offer it.");
    assert_eq!(asked["confirmLabel"], "Remove");
    assert_eq!(asked["destructive"], true);
    hub.dispatch(
        "confirmation.answer",
        json!({"requestId": asked["requestId"], "accepted": false}),
    );
    assert!(offered_by_label(&hub, "one").is_some());
    let many = ["one", "two", "grove"].map(String::from);
    themes(&hub, |t, e| t.request_remove_many(e, &many));
    let asked = hub.published("confirmation");
    assert_eq!(asked["title"], "Remove 2 themes?");
    hub.dispatch(
        "confirmation.answer",
        json!({"requestId": asked["requestId"], "accepted": true}),
    );
    assert!(offered_by_label(&hub, "one").is_none());
    assert!(offered_by_label(&hub, "two").is_none());
    let device = device(&hub);
    assert!(!device.contains_key("theme"));
    assert!(!device.contains_key("themeHalves"));
    assert_eq!(device["customThemes"].as_array().unwrap().len(), 1);
    // Nothing to remove.
    assert!(!themes(&hub, |t, e| t.remove_custom(e, "one")));
    // A theme that cannot be removed stays, and says so.
    let _locked = lock(&hub, dir.path());
    assert!(!themes(&hub, |t, e| t.remove_custom(e, "three")));
    assert!(offered_by_label(&hub, "three").is_some());
    assert!(
        toasts(&hub)
            .iter()
            .any(|(title, _)| title == "Couldn’t remove theme")
    );
}

#[test]
fn the_editor_keeps_a_draft_while_open() {
    let (hub, _dir) = hub();
    themes(&hub, |t, e| t.set_editor_open(e, true));
    let opened = themes(&hub, |t, _| t.editing());
    assert_eq!(opened["label"], "HAL-C2");
    assert_eq!(opened["colors"]["canvas"], "#fcfcfc");
    let mut changed = opened.clone();
    changed["colors"]["canvas"] = json!("#123456");
    themes(&hub, |t, e| t.set_editing(e, changed.clone()));
    assert_eq!(themes(&hub, |t, _| t.editing()), changed);
    // Closed, the draft goes; a draft is kept only while open.
    themes(&hub, |t, e| t.set_editor_open(e, false));
    assert!(themes(&hub, |t, _| t.editing()).is_empty());
    themes(&hub, |t, e| t.set_editing(e, changed.clone()));
    assert!(themes(&hub, |t, _| t.editing()).is_empty());
    // Opened on a draft given.
    themes(&hub, |t, e| t.edit(e, changed.clone()));
    assert!(themes(&hub, |t, _| t.editor_open()));
    assert_eq!(themes(&hub, |t, _| t.editing()), changed);
}

/// A press outside the editor closes it but keeps what was changed, for the
/// toggle to reopen; Escape, Cancel and Save (set_editor_open) let it go.
#[test]
fn a_press_outside_the_editor_keeps_what_was_changed() {
    let (hub, _dir) = hub();
    // With nothing changed there is nothing to keep.
    themes(&hub, |t, e| t.set_editor_open(e, true));
    themes(&hub, |t, e| t.hide_editor(e));
    assert!(!themes(&hub, |t, _| t.editor_open()));
    assert!(themes(&hub, |t, _| t.editing()).is_empty());

    themes(&hub, |t, e| t.set_editor_open(e, true));
    let mut renamed = themes(&hub, |t, _| t.editing());
    renamed.insert("label".into(), json!("Half done"));
    themes(&hub, |t, e| t.set_editing(e, renamed.clone()));
    themes(&hub, |t, e| t.hide_editor(e));
    assert!(!themes(&hub, |t, _| t.editor_open()));
    assert_eq!(themes(&hub, |t, _| t.editing()), renamed);
    // Not open, so it changes nothing more.
    themes(&hub, |t, e| t.hide_editor(e));
    assert_eq!(themes(&hub, |t, _| t.editing()), renamed);
    // The toggle reopens it on the changes, and closing it any other way
    // lets them go.
    themes(&hub, |t, e| t.set_editor_open(e, true));
    assert_eq!(themes(&hub, |t, _| t.editing()), renamed);
    themes(&hub, |t, e| t.set_editor_open(e, false));
    assert!(themes(&hub, |t, _| t.editing()).is_empty());
    themes(&hub, |t, e| t.set_editor_open(e, true));
    assert_eq!(themes(&hub, |t, _| t.editing())["label"], "HAL-C2");

    // Another theme's Edit replaces a draft hide_editor kept.
    themes(&hub, |t, e| t.set_editing(e, renamed.clone()));
    themes(&hub, |t, e| t.hide_editor(e));
    let mut other = renamed.clone();
    other.insert("label".into(), json!("Other"));
    themes(&hub, |t, e| t.edit(e, other.clone()));
    assert_eq!(themes(&hub, |t, _| t.editing()), other);
    // Changed back to what it opened on, there is nothing to keep.
    themes(&hub, |t, e| t.set_editing(e, renamed.clone()));
    themes(&hub, |t, e| t.set_editing(e, other.clone()));
    themes(&hub, |t, e| t.hide_editor(e));
    assert!(themes(&hub, |t, _| t.editing()).is_empty());
}

#[test]
fn picking_a_colour_names_the_roles_drawn_in_it() {
    let (hub, _dir) = hub();
    themes(&hub, |t, e| t.set_editor_open(e, true));
    // Only while inspecting.
    themes(&hub, |t, e| t.pick(e, "#fcfcfc"));
    assert!(themes(&hub, |t, _| t.picked()).is_empty());
    themes(&hub, |t, e| t.set_inspecting(e, true));
    themes(&hub, |t, e| t.pick(e, "#FCFCFC"));
    let picked = themes(&hub, |t, _| t.picked());
    assert!(!themes(&hub, |t, _| t.inspecting()));
    assert_eq!(picked["color"], "#fcfcfc");
    let roles = picked["roles"].as_array().unwrap();
    assert!(roles.contains(&json!("canvas")), "{picked:?}");
    assert_eq!(picked["count"], roles.len());
    assert_eq!(picked["role"], roles[0]);
    // A colour nothing is drawn in.
    themes(&hub, |t, e| t.set_inspecting(e, true));
    assert!(themes(&hub, |t, _| t.picked()).is_empty());
    themes(&hub, |t, e| t.pick(e, "#010203"));
    let picked = themes(&hub, |t, _| t.picked());
    assert_eq!(picked["count"], 0);
    assert_eq!(picked["role"], "");
    // Closing the editor ends inspecting and forgets the pick.
    themes(&hub, |t, e| t.set_inspecting(e, true));
    themes(&hub, |t, e| t.set_editor_open(e, false));
    assert!(!themes(&hub, |t, _| t.inspecting()));
    assert!(themes(&hub, |t, _| t.picked()).is_empty());
}

#[test]
fn a_palette_derives_from_a_canvas_and_an_accent() {
    let dark = derive_palette("#101418", "#3b82f6");
    assert_eq!(dark["canvas"], "#101418");
    assert_eq!(dark["accent"], "#3b82f6");
    assert!(dark.len() > 20);
    let light = derive_palette("#fafafa", "#3b82f6");
    assert_ne!(light["text"], dark["text"]);
    assert!(derive_palette("nothing", "#3b82f6").is_empty());
}

// -- Importing and exporting -------------------------------------------------------

const NORD: &str = r##"{"version": 1, "id": "nord", "name": "Nord", "appearance": "dark",
  "colors": {"canvas": "#2e3440", "accent": "#88c0d0"}}"##;

#[test]
fn an_imported_theme_is_added_and_drawn() {
    let (hub, _dir) = hub();
    assert!(themes(&hub, |t, e| t.import_text(e, NORD)));
    // One appearance: its half.
    assert_eq!(themes(&hub, |t, _| t.halves())["dark"], "nord");
    assert!(toasts(&hub).contains(&("Nord added".into(), "It’s now your dark theme.".into())));
    // Again: it would replace the one saved.
    assert!(!themes(&hub, |t, e| t.import_text(e, NORD)));
    assert_eq!(themes(&hub, |t, _| t.import_conflicts()), ["Nord"]);
    themes(&hub, |t, e| t.resolve_import(e, "copy"));
    assert!(themes(&hub, |t, _| t.import_conflicts()).is_empty());
    assert!(offered_by_label(&hub, "Nord (2)").is_some());
    assert!(themes(&hub, |t, e| !t.import_text(e, NORD)));
    themes(&hub, |t, e| t.resolve_import(e, "update"));
    assert!(
        toasts(&hub)
            .iter()
            .any(|(title, _)| title == "Nord updated")
    );
    assert!(!themes(&hub, |t, e| t.import_text(e, NORD)));
    themes(&hub, |t, e| t.resolve_import(e, "cancel"));
    assert!(themes(&hub, |t, _| t.import_conflicts()).is_empty());
    assert_eq!(
        offered(&hub)
            .iter()
            .filter(|t| t["source"] == "custom")
            .count(),
        2
    );
}

/// The standard look has no row of its own to give way, so an imported file
/// may not take its id, named or made from the name "HAL-C2".
#[test]
fn an_imported_theme_cannot_take_the_standard_looks_id() {
    let (hub, _dir) = hub();
    let before = offered(&hub);
    for id in [Some("hal-c2"), None] {
        let mut file = json!({"version": 1, "name": "HAL-C2", "appearance": "dark",
                              "colors": {"canvas": "#101010"}});
        if let Some(id) = id {
            file["id"] = json!(id);
        }
        assert!(!themes(&hub, |t, e| t.import_text(e, &file.to_string())));
        assert_eq!(
            themes(&hub, |t, _| t.import_error()),
            "The theme id \"hal-c2\" is reserved."
        );
        themes(&hub, |t, e| t.clear_import(e));
    }
    assert_eq!(offered(&hub), before);
}

#[test]
fn a_file_that_is_not_a_theme_says_why() {
    let (hub, _dir) = hub();
    assert!(!themes(&hub, |t, e| t.import_text(e, "{")));
    assert!(!themes(&hub, |t, _| t.import_error()).is_empty());
    // Cleared by the next try.
    assert!(themes(&hub, |t, e| t.import_text(e, NORD)));
    assert_eq!(themes(&hub, |t, _| t.import_error()), "");
    let reserved = r##"{"version": 1, "id": "grove", "name": "Grove", "appearance": "light",
      "colors": {"canvas": "#ffffff"}}"##;
    assert!(!themes(&hub, |t, e| t.import_text(e, reserved)));
    assert!(!themes(&hub, |t, _| t.import_error()).is_empty());
    let huge = " ".repeat(300 * 1024);
    assert!(!themes(&hub, |t, e| t.import_text(e, &huge)));
    assert!(themes(&hub, |t, _| t.import_error()).starts_with("That file is"));
    themes(&hub, |t, e| t.clear_import(e));
    assert_eq!(themes(&hub, |t, _| t.import_error()), "");
}

#[test]
fn a_vs_code_theme_imports_as_a_palette() {
    let (hub, _dir) = hub();
    let vs_code = r##"{"name": "Night Owl", "type": "dark",
      "colors": {"editor.background": "#011627", "editor.foreground": "#d6deeb",
                 "focusBorder": "#122d42", "button.background": "#7e57c2"}}"##;
    assert!(themes(&hub, |t, e| t.import_text(e, vs_code)));
    let theme = offered_by_label(&hub, "Night Owl").unwrap();
    assert_eq!(theme["id"], "night-owl");
    system_dark(&hub, true);
    assert_eq!(resolved(&hub), "night-owl");
    assert_eq!(canvas(&hub), "#011627");
}

#[test]
fn several_files_import_together_without_being_drawn() {
    let (hub, dir) = hub();
    let write = |name: &str, text: &str| {
        let path = dir.path().join(name);
        std::fs::write(&path, text).unwrap();
        path.to_string_lossy().into_owned()
    };
    let nord = write("nord.json", NORD);
    let paper = write(
        "paper.json",
        r##"{"version": 1, "id": "paper", "name": "Paper", "appearance": "light",
             "colors": {"canvas": "#fafaf8"}}"##,
    );
    let broken = write("broken.json", "{");
    let missing = dir
        .path()
        .join("missing.json")
        .to_string_lossy()
        .into_owned();
    themes(&hub, |t, e| t.import_files(e, std::slice::from_ref(&nord)));
    themes(&hub, |t, e| {
        t.import_files(
            e,
            &[nord.clone(), paper.clone(), broken.clone(), missing.clone()],
        )
    });
    assert!(offered_by_label(&hub, "Paper").is_some());
    // Only the one imported alone is drawn.
    assert_eq!(themes(&hub, |t, _| t.halves()), {
        let mut halves = Map::new();
        halves.insert("dark".into(), json!("nord"));
        halves
    });
    assert!(toasts(&hub).iter().any(|(title, _)| title == "Paper added"));
    assert_eq!(themes(&hub, |t, _| t.import_conflicts()), ["Nord"]);
    let error = themes(&hub, |t, _| t.import_error());
    assert!(error.starts_with("broken.json: "), "{error}");
    assert!(
        error.contains(" — missing.json: Could not read that file."),
        "{error}"
    );
    // One file that cannot be read.
    themes(&hub, |t, e| {
        t.import_files(e, std::slice::from_ref(&missing))
    });
    assert_eq!(
        themes(&hub, |t, _| t.import_error()),
        "Could not read that file. Paste the JSON below instead."
    );
}

#[test]
fn an_exported_theme_imports_back() {
    let (hub, dir) = hub();
    assert!(themes(&hub, |t, e| t.import_text(e, NORD)));
    let path = dir.path().join("exported.json");
    assert!(themes(&hub, |t, e| t.export_theme(e, "nord", &path)));
    assert!(
        toasts(&hub)
            .iter()
            .any(|(title, description)| title == "Nord exported"
                && description == &path.display().to_string())
    );
    let file: Json = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(file["version"], 1);
    assert_eq!(file["id"], "nord");
    assert_eq!(file["name"], "Nord");
    assert_eq!(file["appearance"], "dark");
    assert_eq!(file["colors"]["canvas"], "#2e3440");
    assert!(file.get("variants").is_none());
    // Built-ins export too, with their other appearance.
    let grove = dir.path().join("grove.json");
    assert!(themes(&hub, |t, e| t.export_theme(e, "grove", &grove)));
    let file: Json = serde_json::from_slice(&std::fs::read(&grove).unwrap()).unwrap();
    assert!(file["variants"].as_object().is_some_and(|v| !v.is_empty()));
    // Back in, as a copy beside the one saved.
    themes(&hub, |t, e| {
        t.import_files(e, &[path.to_string_lossy().into_owned()])
    });
    assert_eq!(themes(&hub, |t, _| t.import_conflicts()), ["Nord"]);
    // Nothing of that id, and a place that cannot be written.
    assert!(!themes(&hub, |t, e| t.export_theme(e, "no-such", &path)));
    let nowhere = dir.path().join("no/such/dir/x.json");
    assert!(!themes(&hub, |t, e| t.export_theme(e, "nord", &nowhere)));
    assert!(
        toasts(&hub)
            .iter()
            .any(|(title, _)| title == "Couldn’t export theme")
    );
}

// -- What QML sees -------------------------------------------------------------

/// What the `Themes` singleton says of `name`, as JSON.
fn shown(hub: &Hub, name: &str) -> Json {
    let obj = hub.engine.singleton::<ThemesObject>().unwrap();
    from_value(&hub.engine, &hub.engine.read_by_name(obj, name))
}

fn call(hub: &Hub, method: &str, args: &[Value]) -> Json {
    let obj = hub.engine.singleton::<ThemesObject>().unwrap();
    let value = hub.engine.invoke_by_name(obj, method, args).unwrap();
    from_value(&hub.engine, &value)
}

#[test]
fn the_themes_singleton_shows_and_changes_the_choice() {
    let (hub, _dir) = hub();
    assert_eq!(shown(&hub, "mode"), "system");
    assert_eq!(shown(&hub, "appearance"), "light");
    assert_eq!(shown(&hub, "resolvedId"), "hal-c2");
    assert_eq!(shown(&hub, "standardSwatch")[0], "#fcfcfc");
    assert!(
        shown(&hub, "roles")
            .as_array()
            .is_some_and(|r| !r.is_empty())
    );
    call(&hub, "setMode", &[Value::from("dark")]);
    assert_eq!(shown(&hub, "mode"), "dark");
    assert_eq!(shown(&hub, "appearance"), "dark");
    call(&hub, "choose", &[Value::from("grove")]);
    assert_eq!(shown(&hub, "themeId"), "grove");
    assert_eq!(shown(&hub, "resolvedId"), "grove");
    let current = shown(&hub, "available")
        .as_array()
        .unwrap()
        .iter()
        .any(|t| t["id"] == "grove" && t["source"] == "builtIn");
    assert!(current);
    assert_eq!(call(&hub, "draft", &[Value::from("")])["label"], "Grove");
    // The editor opened from QML drafts the theme drawn.
    let obj = hub.engine.singleton::<ThemesObject>().unwrap();
    hub.engine
        .write_by_name(obj, "editorOpen", Value::Bool(true))
        .unwrap();
    assert_eq!(shown(&hub, "editing")["label"], "Grove");
    call(&hub, "importText", &[Value::from("{")]);
    assert!(!shown(&hub, "importError").as_str().unwrap().is_empty());
    hub.engine
        .write_by_name(obj, "editorOpen", Value::Bool(false))
        .unwrap();
    assert_eq!(shown(&hub, "editing"), json!({}));
    call(&hub, "restoreDefaults", &[]);
    assert_eq!(shown(&hub, "mode"), "system");
    assert_eq!(shown(&hub, "themeId"), "");
}

/// What QML does with the editor: Escape and Cancel write `editorOpen`, a
/// press outside calls `hideEditor`, and a copy of the standard look is
/// `duplicateStandard`.
#[test]
fn the_themes_singleton_hides_the_editor_and_duplicates_the_standard_look() {
    let (hub, _dir) = hub();
    let obj = hub.engine.singleton::<ThemesObject>().unwrap();
    // Whether the editor said it was closed by the time inspecting stopped:
    // the focus-restore on a pick must tell a close from a pick.
    let open_when_inspecting_stopped = Rc::new(Cell::new(None));
    let seen = open_when_inspecting_stopped.clone();
    hub.engine
        .connect_by_name(obj, "inspectingChanged", move |engine, _| {
            if !engine.read_by_name(obj, "inspecting").to_boolean() {
                seen.set(Some(engine.read_by_name(obj, "editorOpen").to_boolean()));
            }
        })
        .unwrap();

    hub.engine
        .write_by_name(obj, "editorOpen", Value::Bool(true))
        .unwrap();
    call(
        &hub,
        "setEditing",
        &[json!({"label": "Half done"}).to_value()],
    );
    hub.engine
        .write_by_name(obj, "inspecting", Value::Bool(true))
        .unwrap();
    call(&hub, "hideEditor", &[]);
    assert_eq!(shown(&hub, "editorOpen"), false);
    assert_eq!(shown(&hub, "inspecting"), false);
    assert_eq!(open_when_inspecting_stopped.get(), Some(false));
    assert_eq!(shown(&hub, "editing")["label"], "Half done");
    // Escape: through the property, and the draft goes.
    hub.engine
        .write_by_name(obj, "editorOpen", Value::Bool(true))
        .unwrap();
    assert_eq!(shown(&hub, "editing")["label"], "Half done");
    hub.engine
        .write_by_name(obj, "editorOpen", Value::Bool(false))
        .unwrap();
    assert_eq!(shown(&hub, "editing"), json!({}));

    assert_eq!(call(&hub, "duplicateStandard", &[]), "hal-c2-copy");
    assert_eq!(shown(&hub, "resolvedId"), "hal-c2-copy");
}

// -- The shell theme file ------------------------------------------------------

/// Waits for the watcher to see theme.json change, then reloads it as the
/// shell's loop does.
fn delivered(hub: &Hub, woken: &mpsc::Receiver<()>, until: impl Fn(&Hub) -> bool) {
    while !until(hub) {
        woken.recv().expect("the watcher wakes the shell");
        hal_c2_shell::theme::deliver(&hub.engine);
    }
}

fn theme_store(hub: &Hub, name: &str) -> String {
    let obj = hub
        .engine
        .singleton::<hal_c2_shell::theme::ThemeStore>()
        .unwrap();
    hub.engine
        .to_js_string(&hub.engine.read_by_name(obj, name))
        .to_string()
}

#[test]
fn the_shell_theme_file_is_followed_as_it_changes() {
    let (hub, dir) = hub();
    let (wake, woken) = mpsc::channel();
    hal_c2_shell::theme::set_wake(&hub.engine, move || {
        let _ = wake.send(());
    });
    let file = dir.path().join("theme.json");
    std::fs::write(
        &file,
        r##"{"colors": {"canvas": "#123456"}, "fonts": {"ui": "Fira Sans"}}"##,
    )
    .unwrap();
    delivered(&hub, &woken, |hub| theme_store(hub, "loaded") == "true");
    assert_eq!(theme_store(&hub, "fontUi"), "Fira Sans");
    assert_eq!(
        hal_c2_shell::theme::application_font_family(&hub.engine),
        "Fira Sans"
    );
    // A syntax error keeps the colours drawn and says why.
    std::fs::write(&file, r##"{ "colors": { "canvas": "#"##).unwrap();
    delivered(&hub, &woken, |hub| {
        !theme_store(hub, "lastError").is_empty()
    });
    assert_eq!(theme_store(&hub, "loaded"), "true");
    assert!(theme_store(&hub, "lastError").starts_with("theme.json"));
    // Removed: the theme chosen in the app again.
    std::fs::remove_file(&file).unwrap();
    delivered(&hub, &woken, |hub| theme_store(hub, "loaded") == "false");
    assert_eq!(theme_store(&hub, "lastError"), "");
}

/// Text with no size of its own beside text sized as the bricks size it.
const UNSIZED: &str = r#"
import QtQuick
import QtQuick.Controls

Item {
    readonly property int plainSize: plain.font.pixelSize
    readonly property real plainWidth: plain.implicitWidth
    readonly property real plainHeight: plain.implicitHeight
    readonly property real sizedWidth: sized.implicitWidth
    readonly property real sizedHeight: sized.implicitHeight
    readonly property int labelSize: label.font.pixelSize
    readonly property string family: plain.font.family

    Text { id: plain; text: "Hamburgefonstiv" }
    Text { id: sized; text: "Hamburgefonstiv"; font.pixelSize: 13 }
    Label { id: label; text: "Hamburgefonstiv" }
}
"#;

/// On macOS desktop-qt's text starts in the system's font at 13 px
/// (`QGuiApplication::font()`, 13 pt at macOS's 72 dpi) where Ljós's
/// starts at 12, so the start the shell gives Ljós on macOS
/// (`theme::system_font`) is what text without a size of its own is.
#[test]
fn macos_text_without_a_size_starts_at_desktop_qts_13_px() {
    let hub = Hub::new();
    let mac = hal_c2_shell::theme::system_font(&Font::fallback(), true, &[]);
    ljos::set_application_font(&hub.engine, Some(&mac));
    let source = crate::common::compile(&[("Unsized", UNSIZED)], &[]);
    let (root, _window) = hub.show(source, "Unsized");
    let read = |name| hub.engine.read_by_name(root, name).to_number();
    assert_eq!(read("plainSize"), 13.0);
    assert_eq!(read("labelSize"), 13.0);
    assert_eq!(read("plainWidth"), read("sizedWidth"));
    assert_eq!(read("plainHeight"), read("sizedHeight"));
    let family = hub.engine.read_by_name(root, "family");
    assert_eq!(hub.engine.to_js_string(&family).to_string(), "system-ui");
}
