//! The theme the shell resolves and draws, the themes the MC publishes, and
//! the shell theme file over them (features/desktop/native-settings.feature,
//! navigation/environment-themes.feature, navigation/appearance.feature);
//! this device's own themes as Settings → Appearance edits them
//! (navigation/theme-editor.feature): desktop-qt's ThemeSteps.cpp.

use std::path::PathBuf;

use hal_c2_shell::controllers::palette::Palette;
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::theme::{Mode, Themes};
use hal_c2_shell::theme;
use ljos::prelude::{ColorScheme, Engine};
use serde_json::{Map, Value, json};

use super::add_project;
use super::connection_health::remove_saved_environment;
use super::settings::{fake_config, publish_themes};
use crate::brick::{self, Brick};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

fn settings(world: &World) -> Settings {
    Settings::of(world.engine())
}

fn themes<R>(world: &World, f: impl FnOnce(&mut Themes, &Engine) -> R) -> Outcome<R> {
    world.with::<Themes, R>(f)
}

fn device_error(world: &World) -> String {
    settings(world).device_error()
}

/// "light", "dark" or "system" for the words the scenarios use.
fn appearance_word(word: &str) -> String {
    word.to_lowercase()
}

fn mode_of(word: &str) -> Outcome<Mode> {
    match Mode::parse(&appearance_word(word)) {
        Some(mode) => Ok(mode),
        None => fail!("{word} is not an appearance"),
    }
}

/// The canvas the shell's theme hands the palette, and the one drawn.
fn published_canvas(world: &World) -> Option<ljos::prelude::Color> {
    theme::parse_css_color(&text(at(&world.state("theme"), "colors.canvas")))
}

fn drawn_canvas(world: &World) -> Option<ljos::prelude::Color> {
    theme::drawn_color(world.engine(), "canvas")
}

fn canvas_name(color: Option<ljos::prelude::Color>) -> String {
    color.map_or_else(|| "(none)".to_owned(), |c| format!("{c:?}"))
}

fn describe(world: &World) -> String {
    let (resolved, appearance) = themes(world, |t, _| (t.resolved_id(), t.appearance()))
        .unwrap_or_else(|_| (String::new(), ""));
    format!(
        "the shell resolved {resolved} ({appearance}), drawing canvas {} from {}",
        canvas_name(drawn_canvas(world)),
        if theme::file_loaded(world.engine()) {
            "the shell theme file"
        } else {
            "the app's theme"
        }
    )
}

fn resolved_id(world: &World) -> String {
    themes(world, |t, _| t.resolved_id()).unwrap_or_default()
}

fn uses_theme(world: &mut World, id: &str) -> Outcome {
    let wanted = id.to_owned();
    let described = id.to_owned();
    world.wait_for_with(
        move |w| {
            resolved_id(w) == wanted
                && text(at(&w.state("theme"), "id")) == wanted
                && drawn_canvas(w) == published_canvas(w)
        },
        move |w| format!("{described}; {}", describe(w)),
    )
}

fn drawn(world: &mut World, appearance: &str) -> Outcome {
    let wanted = appearance.to_owned();
    let described = appearance.to_owned();
    world.wait_for_with(
        move |w| {
            themes(w, |t, _| t.appearance() == wanted).unwrap_or(false)
                && theme::drawn_appearance(w.engine()) == wanted
        },
        move |w| {
            format!(
                "drawn {described}; the palette is {}, {}",
                theme::drawn_appearance(w.engine()),
                describe(w)
            )
        },
    )
}

fn ensure_connected(world: &mut World) -> Outcome {
    if settings(world).ready() {
        return Ok(());
    }
    if !world.mc.connected() {
        world.connect()?;
    }
    world.wait_for("the shell to read the MC's settings", |w| {
        settings(w).ready()
    })
}

/// The MC's published themes in the short form (a canvas and an accent).
fn published(id: &str, canvas: &str) -> Value {
    json!({"id": id, "name": id, "appearance": "dark", "canvas": canvas, "accent": "#ff8800"})
}

fn publish(world: &mut World, environment: &str, list: Vec<Value>) -> Outcome {
    publish_themes(&mut world.mc, environment, list.clone());
    if environment == world.mc.environment_id {
        world.wait_for("the shell to hear of the published themes", move |w| {
            settings(w).themes() == list
        })?;
    }
    Ok(())
}

fn custom_themes(world: &World) -> Vec<Value> {
    settings(world)
        .device()
        .get("customThemes")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
}

fn save_custom(world: &mut World, theme: Value) -> Outcome {
    let mut custom = custom_themes(world);
    custom.push(theme);
    let saved = settings(world).write_device(world.engine(), "customThemes", Value::Array(custom));
    expect!(saved, "{}", device_error(world));
    world.pump()
}

fn choose(world: &mut World, id: &str) -> Outcome {
    let chosen = themes(world, |t, e| t.choose(e, id))?;
    expect!(chosen, "{}", device_error(world));
    world.pump()
}

fn choose_half(world: &mut World, appearance: &str, id: &str) -> Outcome {
    let chosen = themes(world, |t, e| t.choose_half(e, appearance, id))?;
    expect!(chosen, "{}", device_error(world));
    world.pump()
}

fn set_mode(world: &mut World, word: &str) -> Outcome {
    let mode = mode_of(word)?;
    let set = themes(world, |t, e| t.set_mode(e, mode))?;
    expect!(set, "{}", device_error(world));
    world.pump()
}

/// The operating system turns dark or light.
pub fn set_system_dark(world: &mut World, dark: bool) -> Outcome {
    ljos::testing::update_system_prefs(world.engine(), |p| {
        p.color_scheme = if dark {
            ColorScheme::Dark
        } else {
            ColorScheme::Light
        }
    });
    world.pump()
}

fn theme_file(world: &World) -> PathBuf {
    world.config_dir().join("theme.json")
}

fn write_theme_file(world: &World, content: &[u8]) -> Outcome {
    let path = theme_file(world);
    if std::fs::write(&path, content).is_err() {
        fail!("cannot write {}", path.display());
    }
    Ok(())
}

fn write_theme_json(world: &World, theme: Value) -> Outcome {
    write_theme_file(world, theme.to_string().as_bytes())
}

fn shell_running(world: &mut World) -> Outcome {
    world.connect()?;
    world.wait_for("the shell to start", |w| w.active())
}

/// A theme of this device's by that name (its id), with a palette for each
/// appearance named; the ones the scenarios name are made up here.
fn ensure_theme(world: &mut World, name: &str, appearances: &[&str]) -> Outcome {
    let known = themes(world, |t, _| t.available())?
        .iter()
        .any(|theme| text(&theme["id"]) == name);
    if known {
        return Ok(());
    }
    let dark = json!({"canvas": "#2e3440", "accent": "#88c0d0"});
    let light = json!({"canvas": "#eceff4", "accent": "#5e81ac"});
    let first = appearances.first().copied().unwrap_or("dark");
    let mut theme = json!({"id": name, "label": name, "appearance": first,
        "colors": if first == "dark" { dark } else { light.clone() }});
    if appearances.len() > 1 {
        theme["variants"] = json!({"light": light});
    }
    save_custom(world, theme)
}

const BOTH: &[&str] = &["dark", "light"];

/// This device's themes (`ensureTheme` of ThemeLibrarySteps, for steps of
/// other files).
pub fn ensure_standard_theme(world: &mut World, name: &str) -> Outcome {
    ensure_theme(world, name, BOTH)
}

/// Makes the device's preferences, as they are, unwritable: every later save
/// fails. Writable again when the scenario ends, so its home can be removed.
#[derive(Default)]
struct Locked {
    folder: Option<PathBuf>,
    file: Option<PathBuf>,
}

impl Drop for Locked {
    fn drop(&mut self) {
        use std::os::unix::fs::PermissionsExt;
        if let Some(folder) = &self.folder {
            let _ = std::fs::set_permissions(folder, std::fs::Permissions::from_mode(0o700));
        }
        if let Some(file) = &self.file {
            let _ = std::fs::set_permissions(file, std::fs::Permissions::from_mode(0o600));
        }
    }
}

pub fn block_device(world: &mut World) -> Outcome {
    use std::os::unix::fs::PermissionsExt;
    let folder = world.config_dir().join("locked");
    let path = folder.join("preferences.json");
    if std::fs::create_dir_all(&folder).is_err() {
        fail!("cannot make {}", folder.display());
    }
    let device = Value::Object(settings(world).device());
    let body = serde_json::to_vec_pretty(&device).unwrap_or_default();
    if std::fs::write(&path, body).is_err() {
        fail!("cannot write {}", path.display());
    }
    settings(world).set_device_path(world.engine(), Some(path.clone()));
    let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o400));
    let _ = std::fs::set_permissions(&folder, std::fs::Permissions::from_mode(0o500));
    let locked = world.part::<Locked>();
    locked.folder = Some(folder);
    locked.file = Some(path);
    world.pump()
}

fn offered(world: &World, label: &str) -> Option<Value> {
    themes(world, |t, _| t.available())
        .ok()?
        .into_iter()
        .find(|theme| text(&theme["label"]) == label)
}

fn offered_themes(world: &World) -> String {
    show(&Value::Array(
        themes(world, |t, _| t.available()).unwrap_or_default(),
    ))
}

const SHELL_CANVAS: &str = "#123456";

fn shell_canvas() -> Option<ljos::prelude::Color> {
    theme::parse_css_color(SHELL_CANVAS)
}

fn draft_of(world: &World, id: &str) -> Outcome<Map<String, Value>> {
    themes(world, |t, e| t.draft(e, id))
}

pub fn register(steps: &mut Steps) {
    // The choice.
    steps.step("the user is using HAL-C2 on the desktop", |world, _, _| {
        shell_running(world)
    });
    steps.step(
        &format!("the theme choice (?:is|becomes) {Q}"),
        |world, c, _| choose(world, &c[0]),
    );
    steps.step("the theme choice is cleared", |world, _, _| {
        choose(world, "")
    });
    steps.step(
        &format!("the theme choice is {Q} for light and {Q} for dark"),
        |world, c, _| {
            choose_half(world, "light", &c[0])?;
            choose_half(world, "dark", &c[1])
        },
    );
    steps.step(
        &format!("the theme choice is {Q} for (light|dark)"),
        |world, c, _| choose_half(world, &c[1], &c[0]),
    );
    steps.step("the (light|dark) theme choice is cleared", |world, c, _| {
        choose_half(world, &c[0], "")
    });
    steps.step(
        "the appearance choice becomes (Light|Dark|System)",
        |world, c, _| set_mode(world, &c[0]),
    );
    steps.step("the user chose the System appearance", |world, _, _| {
        set_mode(world, "system")
    });
    // Sets the appearance, or checks it as an outcome.
    steps.step("the appearance is (Light|Dark|System)", |world, c, _| {
        if world.checking {
            let mode = themes(world, |t, _| t.mode().name())?;
            expect!(mode == appearance_word(&c[0]), "the appearance is {mode}");
            return Ok(());
        }
        set_mode(world, &c[0])
    });
    steps.step(
        "the operating system (?:is|switches to) (dark|light)",
        |world, c, _| set_system_dark(world, c[0] == "dark"),
    );
    steps.step(
        &format!("the user saved a custom theme {Q} with only a dark palette"),
        |world, c, _| {
            save_custom(
                world,
                json!({"id": c[0], "label": c[0], "appearance": "dark",
                "colors": {"canvas": "#101020"}}),
            )
        },
    );

    // What is drawn.
    steps.step("the app uses the standard theme", |world, _, _| {
        uses_theme(world, "hal-c2")?;
        let dark = themes(world, |t, _| t.appearance() == "dark")?;
        let standard = theme::parse_css_color(if dark { "#0a0a0a" } else { "#fcfcfc" });
        expect!(drawn_canvas(world) == standard, "{}", describe(world));
        Ok(())
    });
    steps.step(&format!("the app uses {Q}"), |world, c, _| {
        uses_theme(world, &c[0])
    });
    steps.step("the app is drawn (dark|light)", |world, c, _| {
        drawn(world, &c[0])
    });
    steps.step(&format!("{Q} is the dark theme"), |world, c, _| {
        let halves = themes(world, |t, _| t.halves())?;
        expect!(
            text(halves.get("dark").unwrap_or(&Value::Null)) == c[0],
            "the halves are {}",
            show(&Value::Object(halves))
        );
        Ok(())
    });
    steps.step(&format!("the light theme is still {Q}"), |world, c, _| {
        let (halves, id) = themes(world, |t, _| (t.halves(), t.theme_id()))?;
        expect!(
            !halves.contains_key("light") && id == c[0],
            "the theme is {id}, the halves {}",
            show(&Value::Object(halves))
        );
        Ok(())
    });

    // Published themes.
    steps.step(
        &format!("the (?:server|MC) publishes {Q}"),
        |world, c, _| {
            ensure_connected(world)?;
            let environment = world.mc.environment_id.clone();
            publish(world, &environment, vec![published(&c[0], "#111111")])
        },
    );
    steps.step(
        &format!("the user selected the published theme {Q}"),
        |world, c, _| {
            ensure_connected(world)?;
            let environment = world.mc.environment_id.clone();
            publish(world, &environment, vec![published(&c[0], "#111111")])?;
            // A dark theme, seen in the dark.
            set_system_dark(world, true)?;
            choose(world, &c[0])?;
            uses_theme(world, &c[0])
        },
    );
    steps.step(&format!("the server updates {Q}"), |world, c, _| {
        let environment = world.mc.environment_id.clone();
        publish(world, &environment, vec![published(&c[0], "#222233")])
    });
    steps.step(
        &format!("the server stops publishing {Q}"),
        |world, _, _| {
            let environment = world.mc.environment_id.clone();
            publish(world, &environment, Vec::new())
        },
    );
    steps.step("the app shows the updated colors", |world, _, _| {
        world.wait_for_with(
            |w| drawn_canvas(w) == theme::parse_css_color("#222233"),
            describe,
        )
    });
    steps.step(&format!("the app uses the published {Q}"), |world, c, _| {
        world.wait_for("the shell to read the MC's settings again", |w| {
            settings(w).ready()
        })?;
        uses_theme(world, &c[0])?;
        let environment = world.mc.environment_id.clone();
        let list = fake_config(&mut world.mc)
            .themes
            .get(&environment)
            .cloned()
            .unwrap_or_default();
        let canvas = list
            .first()
            .map(|theme| text(&theme["canvas"]))
            .unwrap_or_default();
        expect!(
            drawn_canvas(world) == theme::parse_css_color(&canvas),
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        &format!("the user saved a custom theme with the id {Q}"),
        |world, c, _| {
            save_custom(
                world,
                json!({"id": c[0], "label": format!("My {}", c[0]), "appearance": "dark",
                "colors": {"canvas": "#333333"}}),
            )?;
            set_system_dark(world, true)?;
            choose(world, &c[0])
        },
    );
    steps.step(
        &format!("the app uses the user's saved {Q}"),
        |world, c, _| {
            uses_theme(world, &c[0])?;
            expect!(
                drawn_canvas(world) == theme::parse_css_color("#333333"),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user connected a second environment that publishes {Q}"),
        |world, c, _| {
            ensure_connected(world)?;
            world.mc.join_named("env-b");
            publish(world, "env-b", vec![published(&c[0], "#444444")])?;
            world.sync()
        },
    );
    steps.step(&format!("{Q} is not offered"), |world, c, _| {
        if super::files_identity::check_icon_image_offered(world, &c[0], false)? {
            return Ok(());
        }
        if super::move_::machine_not_offered(world, &c[0])? {
            return Ok(());
        }
        world.sync()?;
        super::usage_limits_command::expect_command_not_offered(world, &c[0])?;
        let available = themes(world, |t, _| t.available())?;
        for theme in available {
            expect!(text(&theme["id"]) != c[0], "{} is offered", c[0]);
        }
        // Nor is it a choice of the menu that is open (threads/snooze.feature).
        let menu = world.state("menu");
        for item in at(&menu, "items").as_array().into_iter().flatten() {
            expect!(
                !text(&item["label"]).starts_with(&c[0]),
                "the menu offers {}",
                show(item)
            );
        }
        Ok(())
    });

    // The shell theme file (docs/internals/desktop-qt.md).
    steps.step("the desktop shell is running", |world, _, _| {
        shell_running(world)
    });
    steps.step("the desktop shell is using a shell theme", |world, _, _| {
        shell_running(world)?;
        write_theme_json(world, json!({"colors": {"canvas": SHELL_CANVAS}}))?;
        world.wait_for("the shell theme to load", |w| {
            theme::file_loaded(w.engine()) && drawn_canvas(w) == shell_canvas()
        })
    });
    steps.step(
        "a theme manager writes a new canvas color into the shell theme file",
        |world, _, _| write_theme_json(world, json!({"colors": {"canvas": SHELL_CANVAS}})),
    );
    steps.step("the app uses the new canvas color", |world, _, _| {
        world.wait_for_with(|w| drawn_canvas(w) == shell_canvas(), describe)
    });
    steps.step(
        "the shell theme file is saved with a syntax error",
        |world, _, _| {
            write_theme_file(world, b"{ \"colors\": { \"canvas\": ")?;
            world.wait_for("the shell to read the broken file", |w| {
                !theme::file_error(w.engine()).is_empty()
            })
        },
    );
    steps.step("the app keeps the previous colors", |world, _, _| {
        expect!(drawn_canvas(world) == shell_canvas(), "{}", describe(world));
        Ok(())
    });
    steps.step(
        "the error is available to the user's shell layout",
        |world, _, _| {
            // `Theme.lastError` in QML.
            let error = theme::file_error(world.engine());
            expect!(error.starts_with("theme.json"), "{error}");
            Ok(())
        },
    );
    steps.step("the shell theme file is deleted", |world, _, _| {
        let _ = std::fs::remove_file(theme_file(world));
        Ok(())
    });
    steps.step(
        "the app uses its own selected theme again",
        |world, _, _| {
            world.wait_for_with(
                |w| !theme::file_loaded(w.engine()) && drawn_canvas(w) == published_canvas(w),
                describe,
            )
        },
    );
    steps.step(
        "the shell theme has a light variant with a different canvas",
        |world, _, _| {
            shell_running(world)?;
            write_theme_json(
                world,
                json!({"appearance": "dark", "colors": {"canvas": SHELL_CANVAS},
                "variants": {"light": {"canvas": "#eeeeee"}},
                "window": {"followSystemAppearance": true}}),
            )?;
            world.wait_for("the shell theme to load", |w| {
                theme::file_loaded(w.engine())
            })
        },
    );
    steps.step("the light variant's canvas is used", |world, _, _| {
        world.wait_for_with(
            |w| drawn_canvas(w) == theme::parse_css_color("#eeeeee"),
            describe,
        )
    });
    steps.step(
        "the user's saved theme choice is unchanged",
        |world, _, _| {
            world.sync()?;
            let device = settings(world).device();
            let writes = fake_config(&mut world.mc).writes.len();
            expect!(
                !world.config_dir().join("preferences.json").exists()
                    && device.is_empty()
                    && writes == 0,
                "this device holds {}",
                show(&Value::Object(device))
            );
            Ok(())
        },
    );
    steps.step(
        "Settings → Appearance names the shell theme file and where it is",
        |world, _, _| {
            Brick::show(
                world,
                "import QtQuick\nimport HalC2.Bricks\nAppearanceSettings { width: 720; height: 900 }\n",
                720.0,
                900.0,
            )?;
            let page = brick::shown(world)?;
            let item = |world: &World, name: &str| page.item(world, name);
            let shell_theme = item(world, "shellTheme")?;
            let title = item(world, "shellThemeTitle")?;
            let path = item(world, "shellThemePath")?;
            let shown = page.text_of(world, path, "text");
            expect!(
                page.flag(world, shell_theme, "visible")
                    && page.flag(world, title, "visible")
                    && shown == theme_file(world).to_string_lossy(),
                "the page shows \"{shown}\""
            );
            Ok(())
        },
    );
    steps.step(
        "says its colors are drawn over the theme chosen there",
        |world, _, _| {
            let page = brick::shown(world)?;
            let item = page.item(world, "shellThemeEffect")?;
            let effect = page.text_of(world, item, "text");
            expect!(
                effect.contains("drawn over the theme chosen below")
                    && effect.contains("still saved"),
                "{effect}"
            );
            Ok(())
        },
    );
    // Settings → Appearance and the appearance shortcut.
    steps.step(
        "the user chooses the (System|Light|Dark) appearance",
        |world, c, _| set_mode(world, &c[0]),
    );
    steps.step(
        "the appearance becomes (Light|Dark|System)",
        |world, c, _| set_mode(world, &c[0]),
    );
    steps.step(
        "the app is drawn in the operating system's appearance",
        |world, _, _| {
            for dark in [true, false] {
                set_system_dark(world, dark)?;
                drawn(world, if dark { "dark" } else { "light" })?;
            }
            Ok(())
        },
    );
    steps.step("the user presses the appearance shortcut", |world, _, _| {
        // The keybinding and the command palette both send this.
        world.dispatch("appearance.cycle", Value::Null)
    });
    steps.step(
        &format!("the user chooses the {Q} theme in Settings → Appearance"),
        |world, c, _| {
            ensure_theme(world, &c[0], BOTH)?;
            choose(world, &c[0])
        },
    );
    steps.step(
        &format!("the user picks {Q} for light and {Q} for dark"),
        |world, c, _| {
            ensure_theme(world, &c[0], BOTH)?;
            ensure_theme(world, &c[1], BOTH)?;
            choose_half(world, "light", &c[0])?;
            choose_half(world, "dark", &c[1])
        },
    );
    steps.step(&format!("{Q} only has a dark palette"), |world, c, _| {
        ensure_theme(world, &c[0], &["dark"])
    });
    steps.step(&format!("the user chooses {Q}"), |world, c, _| {
        if super::composer_picker::model_picker_chooses(world, &c[0])? {
            return Ok(());
        }
        // The welcome wizard's Select all / Select none.
        if super::onboarding::onboarding_chooses(world, &c[0])? {
            return Ok(());
        }
        // From an open command palette (its Change theme submenu among them):
        // its entry of that title.
        if add_project::is_open(world) {
            let Some(row) = add_project::row_titled(world, &c[0]) else {
                fail!("the command palette does not list \"{}\"", c[0]);
            };
            world.with::<Palette, _>(|p, e| p.run(e, row as i32))?;
            return world.sync();
        }
        choose(world, &c[0])
    });
    steps.step("the light theme is unchanged", |world, _, _| {
        let (halves, id) = themes(world, |t, _| (t.halves(), t.theme_id()))?;
        expect!(
            !halves.contains_key("light") && id.is_empty(),
            "the theme is {id}, the halves {}",
            show(&Value::Object(halves))
        );
        Ok(())
    });
    steps.step("the theme choice cannot be saved", |world, _, _| {
        block_device(world)
    });
    steps.step("the user chooses a theme", |world, _, _| {
        let chosen = themes(world, |t, e| t.choose(e, "grove"))?;
        expect!(!chosen, "the choice was saved");
        Ok(())
    });

    // This device's own themes (the theme editor).
    steps.step(&format!("the active theme is {Q}"), |world, c, _| {
        // As an outcome, only what the window draws.
        if !world.checking {
            ensure_theme(world, &c[0], BOTH)?;
            choose(world, &c[0])?;
        }
        uses_theme(world, &c[0])
    });
    steps.step("the user creates a theme", |world, _, _| {
        // As Settings' "New theme" does: the active theme's colors, as a new
        // theme.
        let mut draft = draft_of(world, "")?;
        draft.insert("id".into(), json!(""));
        world.theme_draft = Value::Object(draft);
        Ok(())
    });
    steps.step(
        "the theme editor opens with (\\w+)'s colors",
        |world, c, _| {
            let draft = world.theme_draft.clone();
            expect!(
                text(&draft["label"]) == c[0]
                    && theme::parse_css_color(&text(at(&draft, "colors.canvas")))
                        == drawn_canvas(world),
                "the editor holds {}; {}",
                show(&draft),
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the user changed colors in the theme editor",
        |world, _, _| {
            let mut draft = draft_of(world, "")?;
            let mut colors = draft
                .get("colors")
                .and_then(Value::as_object)
                .cloned()
                .unwrap_or_default();
            colors.insert("canvas".into(), json!("#203040"));
            draft.insert("colors".into(), Value::Object(colors));
            draft.insert("label".into(), json!("Edited"));
            world.theme_draft = Value::Object(draft);
            Ok(())
        },
    );
    steps.step("the user saves the changes", |world, _, _| {
        let draft = world.theme_draft.as_object().cloned().unwrap_or_default();
        let id = themes(world, |t, e| t.save_custom(e, &draft))?;
        expect!(!id.is_empty(), "{}", device_error(world));
        world.theme_draft["id"] = json!(id);
        world.pump()
    });
    steps.step("the app uses the edited theme", |world, _, _| {
        let id = text(&world.theme_draft["id"]);
        uses_theme(world, &id)?;
        expect!(
            drawn_canvas(world) == theme::parse_css_color("#203040"),
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step(&format!("the user duplicates {Q}"), |world, c, _| {
        ensure_theme(world, &c[0], BOTH)?;
        let copy = themes(world, |t, e| t.duplicate(e, &c[0]))?;
        expect!(!copy.is_empty(), "{}", device_error(world));
        world.pump()
    });
    steps.step(
        &format!("an editable copy of {Q} is added"),
        |world, c, _| {
            let copy = offered(world, &format!("{} copy", c[0]));
            let Some(copy) = copy.filter(|copy| text(&copy["source"]) == "custom") else {
                fail!("the themes offered are {}", offered_themes(world));
            };
            let original = draft_of(world, &c[0])?;
            let duplicate = draft_of(world, &text(&copy["id"]))?;
            expect!(
                duplicate.get("colors") == original.get("colors"),
                "the copy draws {}, the original {}",
                show(&Value::Object(duplicate)),
                show(&Value::Object(original))
            );
            Ok(())
        },
    );
    steps.step("the user duplicates the standard theme", |world, _, _| {
        let copy = themes(world, |t, e| t.duplicate_standard(e))?;
        expect!(!copy.is_empty(), "{}", device_error(world));
        world.pump()
    });
    steps.step(
        "an editable copy of the standard theme as drawn now is added and becomes the theme in use",
        |world, _, _| {
            let copy = offered(world, "HAL-C2 copy");
            let Some(copy) = copy.filter(|copy| text(&copy["source"]) == "custom") else {
                fail!("the themes offered are {}", offered_themes(world));
            };
            let standard = draft_of(world, "hal-c2")?;
            let duplicate = draft_of(world, &text(&copy["id"]))?;
            expect!(
                duplicate.get("colors") == standard.get("colors"),
                "the copy draws {}, the standard theme {}",
                show(&Value::Object(duplicate)),
                show(&Value::Object(standard))
            );
            // As any saved theme is: the copy is pinned to one appearance, so
            // the app stops following the system's.
            let resolved = resolved_id(world);
            expect!(
                resolved == text(&copy["id"]),
                "the theme in use is {resolved}"
            );
            Ok(())
        },
    );
    // A theme saved before the standard look's id was kept from new ones.
    steps.step(
        "a saved theme has the standard theme's id",
        |world, _, _| {
            save_custom(
                world,
                json!({"id": "hal-c2", "label": "Imposter", "appearance": "dark",
            "colors": {"canvas": "#112233", "accent": "#445566"}}),
            )
        },
    );
    steps.step(
        "the copy of the standard theme draws the standard colors, not the saved theme's",
        |world, _, _| {
            let copy = offered(world, "HAL-C2 copy");
            let Some(copy) = copy.filter(|copy| text(&copy["source"]) == "custom") else {
                fail!("the themes offered are {}", offered_themes(world));
            };
            let drawn = draft_of(world, &text(&copy["id"]))?;
            let canvas = text(at(&Value::Object(drawn.clone()), "colors.canvas"));
            expect!(
                !canvas.is_empty() && canvas != "#112233",
                "the copy draws {}",
                show(&Value::Object(drawn))
            );
            expect!(
                offered(world, "Imposter").is_some(),
                "the saved theme is gone"
            );
            Ok(())
        },
    );
    steps.step("the theme cannot be removed", |world, _, _| {
        ensure_theme(world, "My Theme", BOTH)?;
        world.theme_draft = Value::Object(draft_of(world, "My Theme")?);
        block_device(world)
    });
    steps.step("the user removes it", |world, _, _| {
        if remove_saved_environment(world)? {
            return Ok(());
        }
        if super::files_viewer::remove_viewed_attachment(world)? {
            return Ok(());
        }
        let id = text(&world.theme_draft["id"]);
        let removed = themes(world, |t, e| t.remove_custom(e, &id))?;
        expect!(!removed, "the theme was removed");
        expect!(
            offered(world, "My Theme").is_some(),
            "the theme is no longer offered"
        );
        Ok(())
    });
}
