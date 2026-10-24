//! `theme`: the look the shell resolves and publishes, and `Themes`
//! (ThemeController.cpp; tst_ThemeResolution.cpp and ThemeSteps.cpp,
//! features/navigation/appearance.feature, environment-themes.feature,
//! theme-editor.feature, features/desktop/native-settings.feature).

use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::mpsc;

use hal_c2_shell::Launch;
use hal_c2_shell::commands::Commands;
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::theme::{
    Mode, Themes, ThemesObject, canonical_color, derive_palette,
};
use hal_c2_shell::json::{Json, from_value};
use ljos::prelude::{ColorScheme, Engine, Value};
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
             property string label: label.font.family\n\
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
    assert_eq!(family("code"), "monospace");
    assert_eq!(hub.engine.read_by_name(root, "labelSize").to_number(), 20.0);

    assert!(settings.write_device(&hub.engine, "fontFamilySans", json!("")));
    hub.advance(0);
    assert_eq!(family("label"), desktop);
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
