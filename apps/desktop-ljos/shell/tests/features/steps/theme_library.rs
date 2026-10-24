//! This device's theme library: the theme editor as the desktop draws it
//! (qml/HalC2/Bricks/ThemeEditor.qml over the themes controller's draft),
//! importing, exporting and removing themes
//! (features/navigation/theme-editor.feature, environment-themes.feature),
//! and the appearance rows that are colours or keys
//! (navigation/appearance.feature): desktop-qt's ThemeLibrarySteps.cpp.

use hal_c2_shell::commands::Commands;
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::theme::Themes;
use hal_c2_shell::theme;
use ljos::keys::{KeyEvent, KeyKind, Modifiers};
use ljos::prelude::{Color, Engine, ObjectId, Value as Qml};
use serde_json::{Map, Value, json};

use super::keybinding::{press_key, send_key, set_key_focus};
use super::settings::publish_themes;
use super::{add_project as palette, plugin};
use crate::brick::{self, Brick, Shown, key_event};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

#[derive(Default)]
struct Library {
    canvas: String,
    accent: String,
    unsaved: Map<String, Value>,
    exported: String,
    route_before: String,
    /// This device's themes before an import.
    before: Vec<Value>,
    /// How solid menus and dialogs were before the glass opacity changed.
    overlay: f64,
}

const NORD_CANVAS: &str = "#2e3440";
const IMPORTED_CANVAS: &str = "#102030";

fn library(world: &mut World) -> &mut Library {
    world.part::<Library>()
}

fn themes<R>(world: &World, f: impl FnOnce(&mut Themes, &Engine) -> R) -> Outcome<R> {
    world.with::<Themes, R>(f)
}

fn settings(world: &World) -> Settings {
    Settings::of(world.engine())
}

fn saved(world: &World) -> Vec<Value> {
    settings(world)
        .device()
        .get("customThemes")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
}

fn saved_named(world: &World, label: &str) -> Option<Value> {
    saved(world)
        .into_iter()
        .find(|theme| text(&theme["label"]) == label)
}

fn import_error(world: &World) -> String {
    themes(world, |t, _| t.import_error()).unwrap_or_default()
}

fn import_conflicts(world: &World) -> Vec<String> {
    themes(world, |t, _| t.import_conflicts()).unwrap_or_default()
}

fn describe(world: &World) -> String {
    format!(
        "this device has {}; the import says \"{}\", waiting on {}",
        show(&Value::Array(saved(world))),
        import_error(world),
        show(&json!(import_conflicts(world)))
    )
}

/// A saved theme of this device by that name, made up when there is none.
fn ensure_theme(world: &mut World, name: &str, canvas: &str) -> Outcome<String> {
    if let Some(theme) = saved_named(world, name) {
        return Ok(text(&theme["id"]));
    }
    let mut custom = saved(world);
    let id = name.to_lowercase().replace(' ', "-");
    custom.push(json!({"id": id, "label": name, "appearance": "dark",
        "colors": {"canvas": canvas, "accent": "#88c0d0"}}));
    let written =
        settings(world).write_device(world.engine(), "customThemes", Value::Array(custom));
    expect!(written, "{}", settings(world).device_error());
    world.pump()?;
    Ok(id)
}

/// A theme file as the Theme Editor exports it.
fn theme_file(name: &str, canvas: &str, id: &str) -> Value {
    let mut file = json!({"version": 1, "name": name, "appearance": "dark",
        "colors": {"canvas": canvas, "accent": "#ff8800"}});
    if !id.is_empty() {
        file["id"] = json!(id);
    }
    file
}

fn pretty(value: &Value) -> Vec<u8> {
    serde_json::to_vec_pretty(value).unwrap_or_default()
}

fn write_file(world: &World, name: &str, content: &[u8]) -> Outcome<String> {
    let dir = world.home_dir().join("downloads");
    if std::fs::create_dir_all(&dir).is_err() {
        fail!("cannot make {}", dir.display());
    }
    let path = dir.join(name);
    if std::fs::write(&path, content).is_err() {
        fail!("cannot write {}", path.display());
    }
    Ok(path.to_string_lossy().into_owned())
}

fn color(value: &Value) -> Option<Color> {
    theme::parse_css_color(&text(value))
}

fn linear(channel: f64) -> f64 {
    if channel <= 0.04045 {
        channel / 12.92
    } else {
        ((channel + 0.055) / 1.055).powf(2.4)
    }
}

fn relative_luminance(color: Color) -> f64 {
    let [r, g, b, _] = color.to_rgba_f();
    0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
}

fn contrast(a: Color, b: Color) -> f64 {
    let (la, lb) = (relative_luminance(a), relative_luminance(b));
    (la.max(lb) + 0.05) / (la.min(lb) + 0.05)
}

fn hex_of(color: Color) -> String {
    let [r, g, b, _] = color.to_rgba8();
    format!("#{r:02x}{g:02x}{b:02x}")
}

fn number(value: &Qml) -> f64 {
    match value {
        Qml::Real(r) => *r,
        Qml::Int(i) => f64::from(*i),
        _ => 0.0,
    }
}

fn read(world: &World, item: ObjectId, name: &str) -> Qml {
    world.engine().read_by_name(item, name)
}

fn is_true(world: &World, item: ObjectId, name: &str) -> bool {
    read(world, item, name) == Qml::Bool(true)
}

fn text_of(world: &World, item: ObjectId, name: &str) -> String {
    let engine = world.engine();
    engine
        .to_js_string(&engine.read_by_name(item, name))
        .to_string()
}

/// The object a brick's root names by `alias`.
fn alias(world: &World, brick: &Brick, name: &str) -> Outcome<ObjectId> {
    let Some(root) = brick.root(world) else {
        fail!("the brick has no root");
    };
    match read(world, root, name) {
        Qml::Object(object) => Ok(object),
        _ => fail!("the brick has no {name}"),
    }
}

fn opened(world: &World, brick: &Brick, dialog: &str) -> bool {
    alias(world, brick, dialog)
        .map(|object| is_true(world, object, "opened"))
        .unwrap_or(false)
}

/// The brick the scenario shows, made with `qml` when none is yet.
fn shown_or(world: &mut World, qml: &str, width: f64, height: f64) -> Outcome<Brick> {
    if world
        .peek_part::<Shown>()
        .and_then(|shown| shown.0)
        .is_none()
    {
        Brick::show(world, qml, width, height)?;
    }
    brick::shown(world)
}

/// The brick keeps the keys the scenario presses.
fn takes_keys(world: &mut World, mut brick: Brick) -> Brick {
    brick.takes_keys = true;
    world.part::<Shown>().0 = Some(brick);
    brick
}

fn click_key(world: &mut World, spelt: &str) -> Outcome<bool> {
    let event = key_event(spelt)?;
    let release = KeyEvent::release(event.key).with_modifiers(event.modifiers);
    let taken = world.key(&event)?;
    world.key(&release)?;
    Ok(taken)
}

fn type_char(world: &mut World, ch: char) -> Outcome {
    let upper = ch.to_ascii_uppercase();
    let mut event = KeyEvent::press(upper as i32).with_text(ch.to_string());
    if ch.is_ascii_uppercase() {
        event = event.with_modifiers(Modifiers::SHIFT);
    }
    let release = KeyEvent::release(event.key).with_modifiers(event.modifiers);
    world.key(&event)?;
    world.key(&release)?;
    Ok(())
}

fn focus(world: &mut World, item: ObjectId) -> Outcome {
    let _ = world.engine().invoke_by_name(item, "forceActiveFocus", &[]);
    world.pump()
}

/// Replaces a field's text as the user does: select all, type, Enter.
fn type_into(world: &mut World, brick: &Brick, object_name: &str, typed: &str) -> Outcome {
    let field = brick.item(world, object_name)?;
    focus(world, field)?;
    expect!(
        is_true(world, field, "activeFocus"),
        "{object_name} did not take the keyboard"
    );
    click_key(world, "mod+a")?;
    for ch in typed.chars() {
        type_char(world, ch)?;
    }
    click_key(world, "enter")?;
    Ok(())
}

fn editor_qml() -> &'static str {
    "import QtQuick\nimport HalC2.Bricks\n\
     Item { width: 720; height: 760; property alias editor: editor; ThemeEditor { id: editor } }\n"
}

/// The editor over a bare window, as ShellWindow holds it.
fn editor(world: &mut World) -> Outcome<Brick> {
    let fresh = world
        .peek_part::<Shown>()
        .and_then(|shown| shown.0)
        .is_none();
    let brick = shown_or(world, editor_qml(), 720.0, 760.0)?;
    if fresh {
        world.wait_for_with(
            |w| opened(w, &brick, "editor"),
            |_| "the theme editor to open".to_owned(),
        )?;
    }
    Ok(brick)
}

fn popup(world: &mut World) -> Outcome<ObjectId> {
    let brick = editor(world)?;
    alias(world, &brick, "editor")
}

fn editing(world: &World) -> Map<String, Value> {
    themes(world, |t, _| t.editing()).unwrap_or_default()
}

fn editing_colors(world: &World) -> Value {
    editing(world).get("colors").cloned().unwrap_or(json!({}))
}

fn editor_rows(world: &mut World) -> Outcome<Vec<Value>> {
    let dialog = popup(world)?;
    let rows = hal_c2_shell::json::from_value(world.engine(), &read(world, dialog, "rows"));
    Ok(rows.as_array().cloned().unwrap_or_default())
}

fn headings(world: &mut World) -> Outcome<Vec<String>> {
    Ok(editor_rows(world)?
        .iter()
        .map(|row| text(&row["heading"]))
        .filter(|heading| !heading.is_empty())
        .collect())
}

fn roles(world: &World) -> Vec<String> {
    themes(world, |t, _| t.roles()).unwrap_or_default()
}

fn run_command(world: &mut World, command: &str) -> Outcome<bool> {
    let ran = Commands::of(world.engine()).run(world.engine(), command);
    world.pump()?;
    Ok(ran)
}

fn editor_open(world: &World) -> bool {
    themes(world, |t, _| t.editor_open()).unwrap_or(false)
}

fn answer(world: &mut World, accepted: bool) -> Outcome {
    if let Some(answer) = world.answer_question.take() {
        return answer(world, accepted);
    }
    plugin::answer_question(world, accepted)
}

fn alias_root(world: &World, brick: &Brick) -> Outcome<ObjectId> {
    match brick.root(world) {
        Some(root) => Ok(root),
        None => fail!("the brick has no root"),
    }
}

/// The ids of the themes the Appearance list marks as in use.
fn marked(world: &World, list: Brick) -> Outcome<Vec<String>> {
    let mut ids = Vec::new();
    let standard = list.item(world, "theme:hal-c2")?;
    if is_true(world, standard, "checked") {
        ids.push("hal-c2".to_owned());
    }
    for theme in themes(world, |t, _| t.available())? {
        let id = text(&theme["id"]);
        let row = list.item(world, &format!("use:{id}"))?;
        if is_true(world, row, "checked") {
            ids.push(id);
        }
    }
    Ok(ids)
}

fn appearance_list(world: &mut World) -> Outcome<Brick> {
    shown_or(
        world,
        "import QtQuick\nimport HalC2.Bricks\nAppearanceSettings { width: 720; height: 900 }\n",
        720.0,
        900.0,
    )
}

/// The colours of the items named `swatch` at or under `item`.
fn swatches(world: &World, item: ObjectId, found: &mut Vec<Qml>) {
    if text_of(world, item, "objectName") == "swatch" {
        found.push(read(world, item, "color"));
    }
    if let Qml::List(children) = read(world, item, "children") {
        for child in children.iter() {
            if let Qml::Object(child) = child {
                swatches(world, *child, found);
            }
        }
    }
}

fn keyboard_qml() -> &'static str {
    "import QtQuick\nimport QtQuick.Controls.Basic\nimport HalC2.Bricks\n\
     Item { width: 720; height: 760; property alias editor: editor; property alias importer: importer\n\
       TextArea { objectName: \"message\"; width: 200; height: 60; focus: true }\n\
       ThemeEditor { id: editor }\n\
       ThemeImportDialog { id: importer } }\n"
}

fn keyboard(world: &mut World) -> Outcome<Brick> {
    shown_or(world, keyboard_qml(), 720.0, 760.0)
}

fn inspected_qml() -> &'static str {
    "import QtQuick\nimport HalC2.Bricks\n\
     Item { width: 900; height: 700; property alias editor: editor\n\
       Sidebar { width: 256; height: parent.height }\n\
       ThemeEditor { id: editor; x: 300 }\n\
       ThemeInspector { anchors.fill: parent } }\n"
}

fn inspected(world: &mut World) -> Outcome<Brick> {
    let fresh = world
        .peek_part::<Shown>()
        .and_then(|shown| shown.0)
        .is_none();
    let brick = shown_or(world, inspected_qml(), 900.0, 700.0)?;
    Ok(if fresh {
        takes_keys(world, brick)
    } else {
        brick
    })
}

fn canvas_of(theme: &Value) -> Option<Color> {
    color(&theme["colors"]["canvas"])
}

pub fn register(steps: &mut Steps) {
    // The editor.
    steps.step("the theme editor is open", |world, _, _| {
        // Its toggle: the palette's entry and the shortcut run it.
        expect!(
            run_command(world, "themeEditor.toggle")? && editor_open(world),
            "the theme editor did not open"
        );
        Ok(())
    });
    steps.step(
        "the user sets the canvas and accent colors",
        |world, _, _| {
            let state = library(world);
            state.canvas = "#1b2433".to_owned();
            state.accent = "#e0a040".to_owned();
            let (canvas, accent) = (state.canvas.clone(), state.accent.clone());
            let brick = editor(world)?;
            type_into(world, &brick, "color:canvas", &canvas)?;
            type_into(world, &brick, "color:accent", &accent)
        },
    );
    steps.step(
        "the rest of the palette is derived from them",
        |world, _, _| {
            let (canvas, accent) = {
                let state = library(world);
                (state.canvas.clone(), state.accent.clone())
            };
            let colors = editing_colors(world);
            let pick = |role: &str| color(&colors[role]);
            expect!(
                pick("canvas") == theme::parse_css_color(&canvas)
                    && pick("accent") == theme::parse_css_color(&accent),
                "{}",
                show(&colors)
            );
            // Every role is set, and the ones that must follow the two do.
            for role in roles(world) {
                expect!(
                    pick(&role).is_some(),
                    "{role} is {}",
                    text(&colors[role.as_str()])
                );
            }
            let (Some(text_color), Some(canvas_color), Some(accent_color)) =
                (pick("text"), pick("canvas"), pick("accent"))
            else {
                fail!("{}", show(&colors));
            };
            expect!(
                contrast(text_color, canvas_color) >= 7.0,
                "text {} on {}",
                hex_of(text_color),
                hex_of(canvas_color)
            );
            expect!(
                pick("sidebar") != Some(canvas_color)
                    && pick("surfaceRaised") != Some(canvas_color)
                    && pick("border") != Some(canvas_color)
                    && pick("focus") == Some(accent_color)
                    && pick("terminalBackground") == Some(canvas_color),
                "{}",
                show(&colors)
            );
            let Some(foreground) = pick("accentForeground") else {
                fail!("{}", show(&colors));
            };
            expect!(
                contrast(foreground, accent_color) >= 4.5,
                "{}",
                show(&colors)
            );
            Ok(())
        },
    );
    steps.step("the user shows the advanced colors", |world, _, _| {
        let brick = editor(world)?;
        brick.click(world, "advanced")
    });
    steps.step(
        "colors are grouped as Foundation, Brand & content, Context and Status",
        |world, _, _| {
            let wanted = ["Foundation", "Brand & content", "Context", "Status"];
            let titles = headings(world)?;
            expect!(titles == wanted, "{}", show(&json!(titles)));
            // Every role is under one of them, and the first family is drawn.
            let listed = editor_rows(world)?
                .iter()
                .filter(|row| !text(&row["role"]).is_empty())
                .count();
            let all = roles(world).len();
            expect!(listed == all, "{listed} of {all} roles are listed");
            // The list makes its rows when the window next lays out.
            let brick = editor(world)?;
            world.wait_for_with(
                |w| {
                    brick.shows(w, "Foundation").unwrap_or(false)
                        && brick.shows(w, "canvas").unwrap_or(false)
                },
                |_| "the advanced list to be drawn".to_owned(),
            )
        },
    );
    steps.step("the user can filter them by name", |world, _, _| {
        let brick = editor(world)?;
        let filter = brick.item(world, "filter")?;
        focus(world, filter)?;
        for ch in "sidebar".chars() {
            type_char(world, ch)?;
        }
        let rows = editor_rows(world)?;
        expect!(
            headings(world)? == ["Context"] && rows.len() > 1,
            "{}",
            show(&Value::Array(rows.clone()))
        );
        for row in &rows {
            let role = text(&row["role"]);
            expect!(
                role.is_empty() || role.to_lowercase().contains("sidebar"),
                "{}",
                show(&Value::Array(rows.clone()))
            );
        }
        Ok(())
    });
    steps.step(
        "the editor ends just under its last control",
        |world, _, _| {
            let dialog = popup(world)?;
            let (height, implicit) = (
                number(&read(world, dialog, "height")),
                number(&read(world, dialog, "implicitHeight")),
            );
            expect!(
                height == implicit && height < 320.0,
                "the editor is {height} tall for {implicit} of content"
            );
            Ok(())
        },
    );
    steps.step("the editor grows for the list of colors", |world, _, _| {
        let brick = editor(world)?;
        let dialog = popup(world)?;
        world.wait_for_with(
            |w| {
                brick
                    .item(w, "roles")
                    .map(|list| number(&read(w, list, "height")) > 200.0)
                    .unwrap_or(false)
            },
            |w| {
                format!(
                    "the list of colors; the editor is {} tall",
                    number(&read(w, dialog, "height"))
                )
            },
        )
    });
    steps.step(
        "the theme editor is open with unsaved changes",
        |world, _, _| {
            let mut draft = themes(world, |t, e| t.draft(e, ""))?;
            draft.insert("id".to_owned(), json!(""));
            let shown = draft.clone();
            themes(world, |t, e| t.edit(e, shown))?;
            let mut colors = draft
                .get("colors")
                .and_then(Value::as_object)
                .cloned()
                .unwrap_or_default();
            colors.insert("canvas".to_owned(), json!("#203040"));
            draft.insert("colors".to_owned(), Value::Object(colors));
            draft.insert("label".to_owned(), json!("Half done"));
            let changed = draft.clone();
            themes(world, |t, e| t.set_editing(e, changed))?;
            world.pump()?;
            library(world).unsaved = draft.clone();
            expect!(
                editor_open(world) && editing(world) == draft,
                "{}",
                show(&Value::Object(editing(world)))
            );
            Ok(())
        },
    );
    steps.step("the user opens a thread", |world, _, _| {
        let project =
            json!({"id": "p1", "title": "p1", "workspaceRoot": "/work/p1", "scripts": []});
        let thread = json!({"id": "t1", "projectId": "p1", "title": "One",
            "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"});
        world.mc.projects.insert("p1".into(), project.clone());
        world.mc.threads.insert("t1".into(), thread.clone());
        world.mc.send_row_of("p1", &project, "project");
        world.mc.send_row("t1", &thread);
        world.sync()?;
        let key = format!("{}:t1", world.mc.environment_id);
        world.dispatch("thread.open", json!({"key": key}))?;
        world.wait_for_with(
            |w| at(&w.state("route"), "kind") == &json!("thread"),
            |w| format!("the thread; the route is {}", show(&w.state("route"))),
        )
    });
    steps.step(
        "the theme editor is still open with the changes",
        |world, _, _| {
            let unsaved = library(world).unsaved.clone();
            expect!(
                editor_open(world) && editing(world) == unsaved,
                "{}",
                show(&Value::Object(editing(world)))
            );
            // And the window still draws it, over the thread.
            let brick = editor(world)?;
            let dialog = alias(world, &brick, "editor")?;
            let name = brick.item(world, "name")?;
            let said = text_of(world, name, "text");
            expect!(
                is_true(world, dialog, "opened") && said == "Half done",
                "the editor shows \"{said}\""
            );
            Ok(())
        },
    );
    steps.step(
        "the user presses the theme editor shortcut",
        |world, _, _| {
            set_key_focus(world, Default::default())?;
            press_key(world, "mod+alt+shift+t")
        },
    );
    steps.step("the theme editor is closed", |world, _, _| {
        let ran = super::keybinding::key_ran(world, "themeEditor.toggle");
        expect!(
            ran && !editor_open(world) && editing(world).is_empty(),
            "{}",
            super::keybinding::describe_key_press(world)
        );
        Ok(())
    });
    // Both dialogs over a bare window, in the theme the shell resolved.
    steps.step(
        "the user opens the theme editor and the import dialog",
        |world, _, _| {
            Brick::show(
                world,
                "import QtQuick\nimport HalC2.Bricks\n\
                 Item { width: 720; height: 760; property alias editor: editor; property alias importer: importer\n\
                   ThemeEditor { id: editor; visible: true }\n\
                   ThemeImportDialog { id: importer; visible: true } }\n",
                720.0,
                760.0,
            )
        },
    );
    steps.step(
        "both are drawn on the theme's dialog surface with text that can be read",
        |world, _, _| {
            let surface = theme::drawn_color(world.engine(), "surfaceOverlay");
            let brick = brick::shown(world)?;
            let Some(surface) = surface else {
                fail!("the theme has no dialog surface");
            };
            expect!(
                relative_luminance(surface) > 0.5,
                "the theme's dialog surface is {}",
                hex_of(surface)
            );
            for name in ["editor", "importer"] {
                let dialog = alias(world, &brick, name)?;
                let Qml::Object(background) = read(world, dialog, "background") else {
                    fail!("the {name} has no background");
                };
                let (Qml::Color(drawn), Qml::Color(ink)) = (
                    read(world, background, "color"),
                    read(world, dialog, "foreground"),
                ) else {
                    fail!("the {name} has no colors");
                };
                expect!(
                    drawn == surface && contrast(ink, drawn) >= 4.5,
                    "the {name} is drawn on {} with {} text",
                    hex_of(drawn),
                    hex_of(ink)
                );
            }
            Ok(())
        },
    );

    // Settings → Appearance's list of themes, as the page draws it.
    steps.step(
        "the user looks at the themes in Settings → Appearance",
        |world, _, _| appearance_list(world).map(|_| ()),
    );
    steps.step(
        &format!("only {Q} is marked as the theme in use, with its colors beside its name"),
        |world, c, _| {
            let list = appearance_list(world)?;
            let ids = marked(world, list)?;
            expect!(ids == [c[0].clone()], "marked: {}", ids.join(", "));
            let swatch: Vec<String> = themes(world, |t, _| t.available())?
                .iter()
                .find(|theme| text(&theme["id"]) == c[0])
                .and_then(|theme| theme["swatch"].as_array().cloned())
                .unwrap_or_default()
                .iter()
                .map(text)
                .collect();
            let list = appearance_list(world)?;
            let row = list.item(world, &format!("use:{}", c[0]))?;
            let mut drawn = Vec::new();
            swatches(world, row, &mut drawn);
            let wanted: Vec<Qml> = swatch
                .iter()
                .filter_map(|css| theme::parse_css_color(css).map(Qml::Color))
                .collect();
            expect!(
                swatch.len() == 3 && drawn == wanted,
                "the theme's colors are {} and {} are drawn",
                swatch.join(", "),
                drawn.len()
            );
            Ok(())
        },
    );
    steps.step("the user picks the standard theme there", |world, _, _| {
        let list = appearance_list(world)?;
        list.click(world, "theme:hal-c2")?;
        world.sync()
    });
    steps.step(
        "only the standard theme is marked as the theme in use",
        |world, _, _| {
            let list = appearance_list(world)?;
            world.wait_for_with(
                |w| marked(w, list).is_ok_and(|ids| ids == ["hal-c2"]),
                |w| {
                    format!(
                        "the standard theme to be marked; marked: {}",
                        marked(w, list).unwrap_or_default().join(", ")
                    )
                },
            )
        },
    );

    // The keyboard: the dialogs over a message field holding it, as the composer does.
    steps.step("the message field has the keyboard", |world, _, _| {
        let brick = keyboard(world)?;
        let message = brick.item(world, "message")?;
        focus(world, message)?;
        expect!(
            is_true(world, message, "activeFocus"),
            "the message field did not take the keyboard"
        );
        Ok(())
    });
    steps.step("the user opens the theme editor", |world, _, _| {
        let brick = keyboard(world)?;
        let draft = themes(world, |t, e| t.draft(e, ""))?;
        themes(world, |t, e| t.edit(e, draft))?;
        world.wait_for_with(
            |w| opened(w, &brick, "editor"),
            |_| "the theme editor to open".to_owned(),
        )
    });
    steps.step(
        "what the user types goes into the theme's name, not the message",
        |world, _, _| {
            let brick = keyboard(world)?;
            let name = brick.item(world, "name")?;
            world.wait_for_with(
                |w| is_true(w, name, "activeFocus"),
                |_| "the theme's name to take the keyboard".to_owned(),
            )?;
            click_key(world, "tab")?;
            click_key(world, "shift+tab")?;
            click_key(world, "end")?;
            type_char(world, 'x')?;
            let message = brick.item(world, "message")?;
            let (named, said) = (
                text_of(world, name, "text"),
                text_of(world, message, "text"),
            );
            expect!(
                named.ends_with('x') && said.is_empty(),
                "the name is \"{named}\" and the message \"{said}\""
            );
            Ok(())
        },
    );
    steps.step(
        "Escape closes the theme editor and gives the keyboard back",
        |world, _, _| {
            let brick = keyboard(world)?;
            click_key(world, "escape")?;
            let message = brick.item(world, "message")?;
            world.wait_for_with(
                |w| {
                    !opened(w, &brick, "editor")
                        && !editor_open(w)
                        && is_true(w, message, "activeFocus")
                },
                |_| "the theme editor to close and the message field to take the keyboard".into(),
            )
        },
    );
    steps.step("the user opens the theme import dialog", |world, _, _| {
        let brick = keyboard(world)?;
        let importer = alias(world, &brick, "importer")?;
        if let Err(error) = world.engine().invoke_by_name(importer, "open", &[]) {
            fail!("open: {error}");
        }
        world.wait_for_with(
            |w| opened(w, &brick, "importer"),
            |_| "the import dialog to open".to_owned(),
        )
    });
    steps.step(
        "what the user types goes into the pasted JSON, not the message",
        |world, _, _| {
            let brick = keyboard(world)?;
            let json = brick.item(world, "json")?;
            world.wait_for_with(
                |w| is_true(w, json, "activeFocus"),
                |_| "the JSON field to take the keyboard".to_owned(),
            )?;
            type_char(world, 'x')?;
            let message = brick.item(world, "message")?;
            let (pasted, said) = (
                text_of(world, json, "text"),
                text_of(world, message, "text"),
            );
            expect!(
                pasted == "x" && said.is_empty(),
                "the JSON is \"{pasted}\" and the message \"{said}\""
            );
            Ok(())
        },
    );
    steps.step("Escape closes the theme import dialog", |world, _, _| {
        let brick = keyboard(world)?;
        click_key(world, "escape")?;
        world.wait_for_with(
            |w| !opened(w, &brick, "importer"),
            |_| "the import dialog to close".to_owned(),
        )
    });

    steps.step("the user presses in the message field", |world, _, _| {
        let brick = keyboard(world)?;
        brick.click(world, "message")
    });
    steps.step(
        "the theme editor closes and the message field keeps what is typed there",
        |world, _, _| {
            let brick = keyboard(world)?;
            world.wait_for_with(
                |w| !opened(w, &brick, "editor") && !editor_open(w),
                |_| "the theme editor to close".to_owned(),
            )?;
            type_char(world, 'x')?;
            let message = brick.item(world, "message")?;
            let said = text_of(world, message, "text");
            expect!(said == "x", "the message is \"{said}\"");
            Ok(())
        },
    );

    steps.step("the user renames the theme in the editor", |world, _, _| {
        let mut draft = editing(world);
        draft.insert("label".to_owned(), json!("Half done"));
        themes(world, |t, e| t.set_editing(e, draft))?;
        world.pump()
    });
    steps.step("the theme editor is toggled open again", |world, _, _| {
        let brick = keyboard(world)?;
        world.wait_for_with(
            |w| !opened(w, &brick, "editor") && !editor_open(w),
            |_| "the theme editor to close".to_owned(),
        )?;
        expect!(
            run_command(world, "themeEditor.toggle")? && editor_open(world),
            "the theme editor did not open"
        );
        world.wait_for_with(
            |w| opened(w, &brick, "editor"),
            |_| "the theme editor to open".to_owned(),
        )
    });
    steps.step("the editor still holds the new name", |world, _, _| {
        let brick = keyboard(world)?;
        let name = brick.item(world, "name")?;
        let said = text_of(world, name, "text");
        expect!(said == "Half done", "the name is \"{said}\"");
        Ok(())
    });

    // Picking a colour off the app: the editor over a sidebar, with the window's inspector.
    steps.step(
        "the user inspects the app and picks the sidebar",
        |world, _, _| {
            let brick = inspected(world)?;
            brick.click(world, "pick")?;
            expect!(
                themes(world, |t, _| t.inspecting())?,
                "the editor did not start inspecting"
            );
            // An empty part of the thread list.
            world.click_at(120.0, 520.0)
        },
    );
    steps.step(
        "the editor shows the color used there and how many places use it",
        |world, _, _| {
            let picked = themes(world, |t, _| t.picked())?;
            let sidebar = theme::drawn_color(world.engine(), "sidebar");
            let used: Vec<String> = picked
                .get("roles")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default()
                .iter()
                .map(text)
                .collect();
            let inspecting = themes(world, |t, _| t.inspecting())?;
            expect!(
                !inspecting
                    && color(&picked["color"]).is_some()
                    && color(&picked["color"]) == sidebar
                    && used.iter().any(|role| role == "sidebar")
                    && picked["count"].as_i64() == i64::try_from(used.len()).ok(),
                "picked {}; the sidebar is {}",
                show(&Value::Object(picked.clone())),
                sidebar.map_or_else(|| "(none)".to_owned(), hex_of)
            );
            let told = format!(
                "{} · {} · used in {} places",
                text(&picked["role"]),
                text(&picked["color"]),
                picked["count"].as_i64().unwrap_or(0)
            );
            let brick = inspected(world)?;
            expect!(
                brick.shows(world, &told)?,
                "the editor does not say \"{told}\""
            );
            Ok(())
        },
    );
    steps.step("the keyboard is back in the theme editor", |world, _, _| {
        let brick = inspected(world)?;
        let pick = brick.item(world, "pick")?;
        world.wait_for_with(
            |w| is_true(w, pick, "activeFocus"),
            |_| "the editor to take the keyboard back".to_owned(),
        )
    });
    steps.step(
        "the user is inspecting the app for a color",
        |world, _, _| {
            expect!(
                run_command(world, "themeEditor.toggle")? && editor_open(world),
                "the theme editor did not open"
            );
            let brick = inspected(world)?;
            brick.click(world, "pick")?;
            expect!(
                themes(world, |t, _| t.inspecting())?,
                "the editor did not start inspecting"
            );
            world.pump()
        },
    );
    steps.step("nothing is picked", |world, _, _| {
        let inspecting = themes(world, |t, _| t.inspecting())?;
        let picked = themes(world, |t, _| t.picked())?;
        expect!(
            !inspecting && picked.is_empty() && editor_open(world),
            "inspecting: {inspecting}, picked {}",
            show(&Value::Object(picked.clone()))
        );
        // And the next click is the app's again.
        let brick = inspected(world)?;
        let inspector = brick.item(world, "themeInspector")?;
        expect!(
            !is_true(world, inspector, "visible"),
            "the inspector still covers the window"
        );
        Ok(())
    });

    // Importing.
    steps.step("the user imports one HAL-C2 theme file", |world, _, _| {
        let body = pretty(&theme_file("Aurora", IMPORTED_CANVAS, ""));
        let path = write_file(world, "aurora.json", &body)?;
        themes(world, |t, e| t.import_files(e, &[path]))?;
        world.pump()
    });
    steps.step("the user imports one VS Code theme file", |world, _, _| {
        // As an extension ships it: workbench colours, some translucent, most left out.
        let file = json!({"name": "aurora-theme", "displayName": "Aurora", "type": "dark",
            "colors": {"editor.background": IMPORTED_CANVAS, "editor.foreground": "#d8dee9",
                "focusBorder": "#88c0d0", "sideBar.background": "#0c1622",
                "list.hoverBackground": "#ffffff1a"},
            "tokenColors": []});
        let path = write_file(world, "aurora-color-theme.json", &pretty(&file))?;
        themes(world, |t, e| t.import_files(e, &[path]))?;
        world.pump()?;
        // Its own colours where it names them, the rest grown from its background.
        let Some(theme) = saved_named(world, "Aurora") else {
            fail!("{}", describe(world));
        };
        let colors = &theme["colors"];
        let pick = |role: &str| color(&colors[role]);
        let (Some(sidebar), Some(foreground)) = (pick("sidebar"), pick("sidebarForeground")) else {
            fail!("{}", show(colors));
        };
        expect!(
            theme["appearance"] == json!("dark")
                && pick("text") == theme::parse_css_color("#d8dee9")
                && pick("accent") == theme::parse_css_color("#88c0d0")
                && pick("sidebar") == theme::parse_css_color("#0c1622")
                && pick("sidebarRowHover").is_some_and(|c| c.to_rgba8()[3] == 255)
                && pick("sidebarRowHover") != Some(sidebar)
                && pick("border").is_some()
                && contrast(foreground, sidebar) >= 4.5,
            "{}",
            show(colors)
        );
        Ok(())
    });
    steps.step("the user pastes a theme's JSON", |world, _, _| {
        let body = String::from_utf8_lossy(&pretty(&theme_file("Aurora", IMPORTED_CANVAS, "")))
            .into_owned();
        let imported = themes(world, |t, e| t.import_text(e, &body))?;
        world.pump()?;
        expect!(imported, "{}", describe(world));
        Ok(())
    });
    steps.step("the theme is added", |world, _, _| {
        let theme = saved_named(world, "Aurora");
        expect!(
            theme.as_ref().and_then(canvas_of) == theme::parse_css_color(IMPORTED_CANVAS)
                && theme.is_some(),
            "{}",
            describe(world)
        );
        let offered = themes(world, |t, _| t.available())?
            .iter()
            .any(|value| value["label"] == json!("Aurora") && value["source"] == json!("custom"));
        expect!(
            offered && import_error(world).is_empty(),
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the user imports three theme files at once",
        |world, _, _| {
            let mut paths = Vec::new();
            for name in ["Aurora", "Borealis", "Corona"] {
                let body = pretty(&theme_file(name, IMPORTED_CANVAS, ""));
                paths.push(write_file(
                    world,
                    &format!("{}.json", name.to_lowercase()),
                    &body,
                )?);
            }
            let active = themes(world, |t, _| t.resolved_id())?;
            themes(world, |t, e| t.import_files(e, &paths))?;
            world.pump()?;
            let now = themes(world, |t, _| t.resolved_id())?;
            expect!(
                saved(world).len() == 3 && now == active,
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the user imports a theme file larger than 256 KB",
        |world, _, _| {
            let mut big = pretty(&theme_file("Huge", IMPORTED_CANVAS, ""));
            big.extend(std::iter::repeat_n(b' ', 300 * 1024));
            let path = write_file(world, "huge.json", &big)?;
            themes(world, |t, e| t.import_files(e, &[path]))?;
            world.pump()
        },
    );
    steps.step(
        "the file is refused with the size limit explained",
        |world, _, _| {
            let error = import_error(world);
            expect!(
                error.contains("limit 256 KB")
                    && error.contains("was not read")
                    && saved(world).is_empty(),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the user imports a theme file that cannot be read",
        |world, _, _| {
            use std::os::unix::fs::PermissionsExt;
            // The import dialog, which says why under its paste field.
            Brick::show(
                world,
                "import QtQuick\nimport HalC2.Bricks\n\
                 Item { ThemeImportDialog { Component.onCompleted: open() } }\n",
                640.0,
                520.0,
            )?;
            let body = pretty(&theme_file("Locked", IMPORTED_CANVAS, ""));
            let path = write_file(world, "locked.json", &body)?;
            let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o0));
            let unreadable = path.clone();
            themes(world, |t, e| t.import_files(e, &[unreadable]))?;
            let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
            world.pump()?;
            expect!(saved(world).is_empty(), "{}", describe(world));
            Ok(())
        },
    );
    steps.step(&format!("{Q} is installed"), |world, c, _| {
        ensure_theme(world, &c[0], NORD_CANVAS)?;
        library(world).before = saved(world);
        Ok(())
    });
    steps.step(
        &format!("the user imports {Q} again and chooses (Update existing|Keep both|Cancel)"),
        |world, c, _| {
            let Some(installed) = saved_named(world, &c[0]) else {
                fail!("{} is not installed", c[0]);
            };
            let id = text(&installed["id"]);
            let body = pretty(&theme_file(&c[0], IMPORTED_CANVAS, &id));
            let path = write_file(world, &format!("{id}.json"), &body)?;
            themes(world, |t, e| t.import_files(e, &[path]))?;
            world.pump()?;
            // Nothing is touched until the user says which.
            let before = library(world).before.clone();
            expect!(
                import_conflicts(world) == [c[0].clone()] && saved(world) == before,
                "{}",
                describe(world)
            );
            let choice = match c[1].as_str() {
                "Update existing" => "update",
                "Keep both" => "copy",
                _ => "cancel",
            };
            themes(world, |t, e| t.resolve_import(e, choice))?;
            world.pump()?;
            expect!(import_conflicts(world).is_empty(), "{}", describe(world));
            Ok(())
        },
    );
    steps.step(&format!("the installed {Q} is replaced"), |world, c, _| {
        let theme = saved_named(world, &c[0]);
        expect!(
            saved(world).len() == 1
                && theme.as_ref().and_then(canvas_of) == theme::parse_css_color(IMPORTED_CANVAS),
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step(&format!("a copy named {Q} is added"), |world, c, _| {
        let copy = saved_named(world, &c[0]);
        let original = saved_named(world, "Nord");
        expect!(
            saved(world).len() == 2
                && copy.as_ref().and_then(canvas_of) == theme::parse_css_color(IMPORTED_CANVAS)
                && original.as_ref().and_then(canvas_of) == theme::parse_css_color(NORD_CANVAS)
                && copy.as_ref().map(|t| t["id"].clone())
                    != original.as_ref().map(|t| t["id"].clone()),
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step("nothing changes", |world, _, _| {
        let before = library(world).before.clone();
        expect!(
            saved(world) == before && import_error(world).is_empty(),
            "{}",
            describe(world)
        );
        Ok(())
    });

    // Exporting and removing.
    steps.step(&format!("the user exports {Q}"), |world, c, _| {
        let id = ensure_theme(world, &c[0], NORD_CANVAS)?;
        let path = world.home_dir().join("my-theme.json");
        library(world).exported = path.to_string_lossy().into_owned();
        let exported = themes(world, |t, e| t.export_theme(e, &id, &path))?;
        expect!(exported, "the theme was not exported");
        Ok(())
    });
    steps.step(
        "a JSON theme file is saved that can be imported elsewhere",
        |world, _, _| {
            let path = library(world).exported.clone();
            let Ok(body) = std::fs::read(&path) else {
                fail!("{path} was not written");
            };
            let theme: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
            expect!(
                theme["version"] == json!(1)
                    && theme["name"] == json!("My Theme")
                    && theme["appearance"] == json!("dark")
                    && canvas_of(&theme) == theme::parse_css_color(NORD_CANVAS),
                "{}",
                show(&theme)
            );
            // Elsewhere: a device that does not have it yet takes the file.
            let id = text(&theme["id"]);
            let removed = themes(world, |t, e| t.remove_custom(e, &id))?;
            world.pump()?;
            expect!(removed && saved(world).is_empty(), "{}", describe(world));
            themes(world, |t, e| t.import_files(e, &[path]))?;
            world.pump()?;
            let back = saved_named(world, "My Theme");
            expect!(
                back.as_ref().and_then(canvas_of) == theme::parse_css_color(NORD_CANVAS),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "an installed collection with four variants",
        |world, _, _| {
            // As an extension's themes arrive: four files of one collection.
            let mut paths = Vec::new();
            for name in ["Aurora Dawn", "Aurora Day", "Aurora Dusk", "Aurora Night"] {
                let mut file = theme_file(name, IMPORTED_CANVAS, "");
                file["collection"] = json!({"id": "acme.aurora", "label": "Aurora"});
                let file_name = format!("{}.json", name.to_lowercase().replace(' ', "-"));
                paths.push(write_file(world, &file_name, &pretty(&file))?);
            }
            themes(world, |t, e| t.import_files(e, &paths))?;
            world.pump()?;
            let in_collection = themes(world, |t, _| t.available())?
                .iter()
                .filter(|value| value["collection"] == json!("Aurora"))
                .count();
            expect!(
                saved(world).len() == 4 && in_collection == 4,
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("the user removes two selected variants", |world, _, _| {
        let ids = vec!["aurora-day".to_owned(), "aurora-dusk".to_owned()];
        themes(world, |t, e| t.request_remove_many(e, &ids))?;
        world.pump()?;
        // Asked once for both.
        let question = world.state("confirmation");
        expect!(
            question["title"] == json!("Remove 2 themes?") && saved(world).len() == 4,
            "{}",
            show(&question)
        );
        answer(world, true)
    });
    steps.step("only those two variants are gone", |world, _, _| {
        let left: Vec<String> = saved(world).iter().map(|v| text(&v["label"])).collect();
        expect!(
            left == ["Aurora Dawn", "Aurora Night"],
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step("the user confirms", |world, _, _| answer(world, true));
    steps.step(&format!("{Q} is gone"), |world, c, _| {
        expect!(saved_named(world, &c[0]).is_none(), "{}", describe(world));
        for value in themes(world, |t, _| t.available())? {
            expect!(value["label"] != json!(c[0]), "{} is still offered", c[0]);
        }
        Ok(())
    });

    // A published theme's copy.
    steps.step(
        &format!("the user has an editable copy that does not change when the server updates {Q}"),
        |world, c, _| {
            let Some(copy) = saved_named(world, &format!("{} copy", c[0])) else {
                fail!("{}", describe(world));
            };
            let id = text(&copy["id"]);
            let before = themes(world, |t, e| t.draft(e, &id))?;
            expect!(
                before.get("id") == Some(&json!(id)),
                "the copy cannot be edited: {}",
                show(&Value::Object(before.clone()))
            );
            // The server changes its colours.
            let updated = vec![json!({"id": c[0], "name": c[0], "appearance": "dark",
                "canvas": "#222233", "accent": "#ff8800"})];
            let environment = world.mc.environment_id.clone();
            publish_themes(&mut world.mc, &environment, updated.clone());
            world.wait_for("the shell to hear of the update", move |w| {
                Settings::of(w.engine()).themes() == updated
            })?;
            let published = themes(world, |t, e| t.draft(e, &c[0]))?;
            expect!(
                color(&published["colors"]["canvas"]) == theme::parse_css_color("#222233"),
                "the published theme did not change"
            );
            let after = themes(world, |t, e| t.draft(e, &id))?;
            expect!(
                after == before,
                "the copy is now {}",
                show(&Value::Object(after.clone()))
            );
            Ok(())
        },
    );

    // Settings → Appearance: keys and the rows that are colours.
    steps.step("the user presses the theme shortcut", |world, _, _| {
        library(world).route_before = show(&world.state("route"));
        set_key_focus(world, Default::default())?;
        press_key(world, "mod+alt+a")
    });
    steps.step("the theme picker opens over the thread", |world, _, _| {
        let submenu = palette::prop(world, "submenu")?;
        expect!(
            super::keybinding::key_ran(world, "theme.select")
                && palette::is_open(world)
                && submenu == "Change theme",
            "{}",
            super::keybinding::describe_key_press(world)
        );
        // The window stays where it was.
        let before = library(world).route_before.clone();
        expect!(
            show(&world.state("route")) == before,
            "the route moved to {}",
            show(&world.state("route"))
        );
        Ok(())
    });
    steps.step("the current theme is marked \"Current\"", |world, _, _| {
        let current: Vec<String> = (0..palette::count(world))
            .filter(|row| palette::role(world, *row, "current") == Qml::Bool(true))
            .map(|row| palette::role_text(world, row, "title"))
            .collect();
        // The standard look, with no theme chosen.
        expect!(current == ["HAL-C2"], "{}", show(&json!(current)));
        Ok(())
    });
    steps.step(
        "the user holds the appearance shortcut down",
        |world, _, _| {
            set_key_focus(world, Default::default())?;
            // The press, then the key repeats while it is held: a window
            // Shortcut fires again only when it repeats (ShellWindow binds
            // autoRepeat to this).
            press_key(world, "mod+alt+shift+a")?;
            let held = Modifiers::CONTROL | Modifiers::ALT | Modifiers::SHIFT;
            for _ in 0..6 {
                send_key(world, KeyKind::Press, i32::from(b'A'), held, true)?;
            }
            Ok(())
        },
    );
    steps.step("font smoothing is not offered", |world, _, _| {
        // The page lists Rows.visible(rows, platform): the row is the Mac's.
        expect!(
            !cfg!(target_os = "macos"),
            "this check is for platforms other than macOS"
        );
        let list = appearance_list(world)?;
        let root = alias_root(world, &list)?;
        let rows = hal_c2_shell::json::from_value(world.engine(), &read(world, root, "rows"));
        let row = rows
            .as_array()
            .and_then(|rows| rows.iter().find(|row| row["key"] == json!("fontSmoothing")))
            .cloned()
            .unwrap_or(Value::Null);
        expect!(
            row["macOnly"] == json!(true),
            "font smoothing is offered nowhere"
        );
        expect!(
            list.find(world, "settingsRow:wordWrap")?.is_some(),
            "the page lists no settings rows"
        );
        expect!(
            list.find(world, "settingsRow:fontSmoothing")?.is_none(),
            "font smoothing is offered on this platform"
        );
        Ok(())
    });
    steps.step(
        &format!("the user sets diff colors to {Q}"),
        |world, c, _| {
            let value = if c[0] == "Blue & orange" {
                "blue-orange"
            } else {
                "red-green"
            };
            settings(world).set(world.engine(), "diffColorScheme", json!(value));
            world.wait_for("the diff colors to be saved", move |w| {
                settings(w).setting(w.engine(), "diffColorScheme") == Some(json!(value))
            })
        },
    );
    steps.step(
        "added and removed lines are shown in (green and red|blue and orange)",
        |world, c, _| {
            // What DiffPanel paints additions and deletions with.
            let added = theme::drawn_color(world.engine(), "diffAdded");
            let removed = theme::drawn_color(world.engine(), "diffRemoved");
            let blue = c[0] == "blue and orange";
            let hue = |color: Color| {
                let [r, g, b, _] = color.to_rgba_f();
                let (max, min) = (r.max(g).max(b), r.min(g).min(b));
                if max == min {
                    return 0.0;
                }
                let delta = max - min;
                let sector = if max == r {
                    ((g - b) / delta).rem_euclid(6.0)
                } else if max == g {
                    (b - r) / delta + 2.0
                } else {
                    (r - g) / delta + 4.0
                };
                sector * 60.0
            };
            let near = |color: Option<Color>, wanted: f64| {
                color.is_some_and(|c| {
                    let diff = (hue(c) - wanted).abs();
                    diff.min(360.0 - diff) <= 25.0
                })
            };
            expect!(
                near(added, if blue { 217.0 } else { 142.0 })
                    && near(removed, if blue { 25.0 } else { 0.0 }),
                "additions are {} (hue {}), deletions {} (hue {})",
                added.map_or_else(|| "(none)".to_owned(), hex_of),
                added.map_or(-1.0, hue),
                removed.map_or_else(|| "(none)".to_owned(), hex_of),
                removed.map_or(-1.0, hue)
            );
            Ok(())
        },
    );
    steps.step("the user sets glass opacity to (\\d+)", |world, c, _| {
        let overlay = theme::drawn_color(world.engine(), "surfaceOverlay")
            .map_or(0.0, |color| color.to_rgba_f()[3]);
        library(world).overlay = overlay;
        let value: i64 = c[0].parse().unwrap_or(0);
        settings(world).set(world.engine(), "glassOpacity", json!(value));
        world.wait_for("the glass opacity to be saved", move |w| {
            settings(w)
                .setting(w.engine(), "glassOpacity")
                .and_then(|v| v.as_i64())
                == Some(value)
        })
    });
    steps.step(
        "translucent surfaces are more see-through",
        |world, _, _| {
            let before = library(world).overlay;
            let now = theme::drawn_color(world.engine(), "surfaceOverlay")
                .map_or(0.0, |color| color.to_rgba_f()[3]);
            expect!(
                now < before && (now - 0.5).abs() < 0.01,
                "menus and dialogs were {before} solid and are now {now}"
            );
            Ok(())
        },
    );
}

/// Removes the theme by that name from the Appearance page ("the user
/// removes it" of ThemeSteps and the settings scenarios): asks to remove
/// it, which the scenario then confirms. False off Settings → Appearance.
pub fn removes_theme(world: &mut World, name: &str) -> Outcome<bool> {
    let route = world.state("route");
    if at(&route, "kind") != &json!("settings")
        || at(&route, "section") != &json!("/settings/appearance")
    {
        return Ok(false);
    }
    let id = ensure_theme(world, name, NORD_CANVAS)?;
    themes(world, |t, e| t.request_remove(e, &id))?;
    world.pump()?;
    Ok(true)
}
