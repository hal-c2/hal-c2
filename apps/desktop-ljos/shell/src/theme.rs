//! `Theme` in `HalC2.Shell`, desktop-qt's ThemeStore: the theme the theme
//! controller publishes as `theme` (the base), with `<configDir>/theme.json`
//! on top, as properties the bricks bind.
//!
//! `palette` is the object itself, notified on every change: the bricks write
//! `Theme.palette.color(role, fallback)`, and reading `palette` is what makes
//! such a call re-run when the theme changes (a call records no dependency).
//!
//! Not ported yet: watching theme.json (it is read at start and on
//! `reload()`), and making `fontUi` the application's font.

use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;

use ljos::prelude::{Atom, Color, Cx, Engine, ObjectId, QmlObject, Value, qml_impl, qml_singleton};

use crate::bridge::Bridge;
use crate::json::Json;
use crate::platform_window;

#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "Theme", uncreatable)]
#[qml_singleton]
pub struct ThemeStore {
    #[qml(notify, readonly)]
    loaded: bool,
    #[qml(notify, readonly)]
    base_loaded: bool,
    #[qml(constant, readonly)]
    path: Atom,
    #[qml(notify, readonly)]
    id: Atom,
    #[qml(notify, readonly)]
    name: Atom,
    #[qml(notify, readonly)]
    appearance: Atom,
    #[qml(notify, readonly)]
    follows_system_appearance: bool,
    #[qml(notify, readonly)]
    last_error: Atom,
    #[qml(notify, readonly)]
    palette: Option<ObjectId>,
    #[qml(notify, readonly)]
    link: Color,
    #[qml(notify, readonly)]
    radius: f64,
    #[qml(notify, readonly)]
    font_ui: Atom,
    #[qml(notify, readonly)]
    font_mono: Atom,
    #[qml(notify, readonly)]
    font_prompt: Atom,
    #[qml(notify, readonly)]
    font_terminal: Atom,
    #[qml(notify, readonly)]
    font_scale: f64,
    #[qml(notify, readonly)]
    font_size_prompt: i32,
    #[qml(notify, readonly)]
    font_size_code: i32,
    #[qml(notify, readonly)]
    font_size_terminal: i32,
    #[qml(notify, readonly)]
    window_opacity: f64,
    #[qml(notify, readonly)]
    window_transparent: bool,
    #[qml(notify, readonly)]
    window_blur: bool,
    #[qml(notify, readonly)]
    window_liquid_glass: bool,
    #[qml(notify, readonly)]
    frameless: bool,
}

impl Default for ThemeStore {
    fn default() -> Self {
        let derived = Derived::of(&ThemeFile::default(), &Base::default());
        ThemeStore {
            loaded: false,
            base_loaded: false,
            path: Atom::from(""),
            id: Atom::from(""),
            name: Atom::from(""),
            appearance: Atom::from(derived.appearance.as_str()),
            follows_system_appearance: false,
            last_error: Atom::from(""),
            palette: None,
            link: derived.link,
            radius: derived.radius,
            font_ui: Atom::from(""),
            font_mono: Atom::from(""),
            font_prompt: Atom::from(""),
            font_terminal: Atom::from(""),
            font_scale: 1.0,
            font_size_prompt: 14,
            font_size_code: 13,
            font_size_terminal: 12,
            window_opacity: 1.0,
            window_transparent: false,
            window_blur: false,
            window_liquid_glass: false,
            frameless: true,
        }
    }
}

#[qml_impl]
impl ThemeStore {
    /// A role's colour (`canvas`, `text`, ...): theme.json's, then the base
    /// theme's, then `fallback`.
    #[qml(invokable)]
    fn color(cx: &Cx, role: Atom, fallback: Value) -> Value {
        let state = ThemeState::of(cx.engine);
        let found = {
            let file = state.file.borrow();
            let base = state.base.borrow();
            [&file.resolved, &base.colors]
                .into_iter()
                .filter_map(|colors| colors.get(&*role).and_then(Json::as_str))
                .find_map(parse_css_color)
        };
        match (found, fallback) {
            (Some(color), _) => Value::Color(color),
            // A brick's fallback is often a string; the property it lands in
            // is a colour.
            (None, Value::String(s)) => Color::parse(&s).map_or(Value::String(s), Value::Color),
            (None, other) => other,
        }
    }

    #[qml(invokable)]
    fn reload(cx: &Cx) {
        reload(cx.engine);
    }
}

/// theme.json as last read.
#[derive(Default)]
struct ThemeFile {
    loaded: bool,
    id: String,
    name: String,
    appearance: String,
    colors: serde_json::Map<String, Json>,
    variants: serde_json::Map<String, Json>,
    /// `colors` with the variant of the appearance on top.
    resolved: serde_json::Map<String, Json>,
    radius: String,
    font_ui: String,
    font_mono: String,
    follows_system_appearance: bool,
    window_opacity: f64,
    window_transparent: bool,
    window_blur: bool,
    window_liquid_glass: bool,
    frameless: bool,
    last_content: Option<Vec<u8>>,
    last_error: String,
}

/// What the theme controller published.
#[derive(Default, PartialEq)]
struct Base {
    theme: Json,
    colors: serde_json::Map<String, Json>,
    appearance: String,
    radius: Option<f64>,
    font_ui: String,
    font_mono: String,
}

#[derive(Default)]
struct ThemeState {
    path: RefCell<Option<PathBuf>>,
    file: RefCell<ThemeFile>,
    base: RefCell<Base>,
}

impl ThemeState {
    fn of(engine: &Engine) -> Rc<ThemeState> {
        engine.extension::<ThemeState>()
    }
}

/// Makes the engine's `Theme`, reading `<config_dir>/theme.json` when there
/// is one, and follows the `theme` the bridge publishes.
pub fn install(engine: &Engine, config_dir: Option<PathBuf>) {
    let obj = engine
        .singleton::<ThemeStore>()
        .expect("HalC2.Shell is registered");
    let path = config_dir.map(|dir| dir.join("theme.json"));
    let cx = Cx::new(engine, obj);
    let shown = path
        .as_ref()
        .map_or(String::new(), |p| p.to_string_lossy().into_owned());
    let _ = cx.set(ThemeStore::PATH, Atom::from(shown.as_str()));
    let _ = cx.set(ThemeStore::PALETTE, Some(obj));
    *ThemeState::of(engine).path.borrow_mut() = path;
    Bridge::of(engine).watch(engine, "theme", apply_base_theme);
    if let Some(theme) = Bridge::of(engine).published(engine, "theme") {
        apply_base_theme(engine, &theme);
    }
    reload(engine);
}

/// The resolved theme the theme controller publishes (`ShellThemeState`).
fn apply_base_theme(engine: &Engine, theme: &Json) {
    let Some(map) = theme.as_object().filter(|m| !m.is_empty()) else {
        return;
    };
    let state = ThemeState::of(engine);
    if state.base.borrow().theme == *theme {
        return;
    }
    let text = |key: &str| {
        map.get(key)
            .and_then(Json::as_str)
            .unwrap_or_default()
            .to_owned()
    };
    *state.base.borrow_mut() = Base {
        theme: theme.clone(),
        colors: map
            .get("colors")
            .and_then(Json::as_object)
            .cloned()
            .unwrap_or_default(),
        appearance: text("appearance"),
        radius: map.get("radius").and_then(Json::as_f64),
        font_ui: text("fontUi"),
        font_mono: text("fontMono"),
    };
    {
        let mut file = state.file.borrow_mut();
        if file.loaded {
            resolve_colors(&mut file, &state.base.borrow());
        }
    }
    show(engine);
}

/// Reads theme.json again. A file that does not parse keeps the last good
/// theme (a half-written file must not flash the defaults).
fn reload(engine: &Engine) {
    let state = ThemeState::of(engine);
    let Some(path) = state.path.borrow().clone() else {
        return;
    };
    let changed = {
        let mut file = state.file.borrow_mut();
        let base = state.base.borrow();
        match std::fs::read(&path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                let had = file.loaded || file.last_content.is_some() || !file.last_error.is_empty();
                if had {
                    *file = ThemeFile::default();
                }
                had
            }
            Err(_) => {
                file.last_error = format!("Cannot read {}", path.display());
                true
            }
            Ok(content)
                if file.last_content.as_ref() == Some(&content)
                    && file.loaded
                    && file.last_error.is_empty() =>
            {
                false
            }
            Ok(content) => {
                match serde_json::from_slice::<Json>(&content) {
                    Ok(Json::Object(root)) => {
                        *file = parse_file(&root);
                        resolve_colors(&mut file, &base);
                    }
                    Ok(_) => file.last_error = "theme.json: not an object".into(),
                    Err(e) => file.last_error = format!("theme.json: {e}"),
                }
                file.last_content = Some(content);
                true
            }
        }
    };
    if changed {
        show(engine);
    }
}

fn parse_file(root: &serde_json::Map<String, Json>) -> ThemeFile {
    let text = |v: Option<&Json>| v.and_then(Json::as_str).unwrap_or_default().to_owned();
    let object = |v: Option<&Json>| v.and_then(Json::as_object).cloned().unwrap_or_default();
    let id = root
        .get("id")
        .and_then(Json::as_str)
        .unwrap_or("shell")
        .to_owned();
    let name = root
        .get("name")
        .and_then(Json::as_str)
        .map_or_else(|| id.clone(), str::to_owned);
    let fonts = object(root.get("fonts"));
    let window = object(root.get("window"));
    let flag =
        |key: &str, default: bool| window.get(key).and_then(Json::as_bool).unwrap_or(default);
    ThemeFile {
        loaded: true,
        name,
        id,
        appearance: if text(root.get("appearance")) == "light" {
            "light"
        } else {
            "dark"
        }
        .into(),
        colors: object(root.get("colors")),
        variants: object(root.get("variants")),
        resolved: Default::default(),
        radius: text(root.get("radius")),
        font_ui: text(fonts.get("ui")),
        font_mono: text(fonts.get("mono")),
        follows_system_appearance: flag("followSystemAppearance", false),
        window_opacity: window
            .get("opacity")
            .and_then(Json::as_f64)
            .unwrap_or(1.0)
            .clamp(0.1, 1.0),
        window_transparent: flag("transparent", false),
        window_blur: flag("blur", false),
        window_liquid_glass: flag("liquidGlass", false),
        frameless: flag("frameless", true),
        last_content: None,
        last_error: String::new(),
    }
}

fn resolve_colors(file: &mut ThemeFile, base: &Base) {
    // Following, the file's variants track the app's appearance (the theme
    // controller's, the system's in its system mode); dark before it says.
    if file.follows_system_appearance {
        file.appearance = if base.appearance == "light" {
            "light"
        } else {
            "dark"
        }
        .into();
    }
    let mut resolved = serde_json::Map::new();
    let variant = file
        .variants
        .get(&file.appearance)
        .and_then(Json::as_object)
        .cloned()
        .unwrap_or_default();
    for colors in [&file.colors, &variant] {
        for (role, value) in colors {
            if is_role_name(role) && value.as_str().is_some_and(is_safe_color_value) {
                resolved.insert(role.clone(), value.clone());
            }
        }
    }
    file.resolved = resolved;
}

fn is_role_name(name: &str) -> bool {
    let mut chars = name.chars();
    chars.next().is_some_and(|c| c.is_ascii_lowercase()) && chars.all(|c| c.is_ascii_alphanumeric())
}

fn is_safe_color_value(value: &str) -> bool {
    !value.is_empty()
        && value.len() < 128
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "#(),.%/ -".contains(c))
}

/// A CSS colour as Ljós reads one: CSS hex puts alpha last (#rrggbbaa),
/// Qt's and Ljós's first (#aarrggbb).
pub fn parse_css_color(value: &str) -> Option<Color> {
    let v = value.trim();
    if let Some(hex) = v.strip_prefix('#') {
        if hex.len() == 8 {
            return Color::parse(&format!("#{}{}", &hex[6..8], &hex[0..6]));
        }
        if hex.len() == 4 {
            let d: Vec<char> = hex.chars().collect();
            let pair = |c: char| format!("{c}{c}");
            return Color::parse(&format!(
                "#{}{}{}{}",
                pair(d[3]),
                pair(d[0]),
                pair(d[1]),
                pair(d[2])
            ));
        }
    }
    Color::parse(v)
}

/// The values the properties show.
struct Derived {
    appearance: String,
    link: Color,
    radius: f64,
    font_ui: String,
    font_mono: String,
    font_prompt: String,
    font_terminal: String,
    font_scale: f64,
    prompt: i32,
    code: i32,
    terminal: i32,
}

impl Derived {
    fn of(file: &ThemeFile, base: &Base) -> Derived {
        let installed = ljos::font_families();
        let appearance = if file.loaded {
            file.appearance.clone()
        } else {
            base.appearance.clone()
        };
        let link = if appearance == "light" {
            "#1d4ed8"
        } else {
            "#60a5fa"
        };
        let font_ui = first_font_family(
            if file.font_ui.is_empty() {
                &base.font_ui
            } else {
                &file.font_ui
            },
            true,
            &installed,
        );
        let font_mono = fixed_width(
            first_font_family(
                if file.font_mono.is_empty() {
                    &base.font_mono
                } else {
                    &file.font_mono
                },
                false,
                &installed,
            ),
            &installed,
        );
        let own = |key: &str| {
            base.theme
                .get(key)
                .and_then(Json::as_str)
                .unwrap_or_default()
        };
        let size = |part: &str, fallback: i32| {
            base.theme
                .pointer(&format!("/fontSizes/{part}"))
                .and_then(Json::as_i64)
                .filter(|s| *s > 0)
                .map_or(fallback, |s| s as i32)
        };
        Derived {
            link: Color::parse(link).expect("a hex colour"),
            radius: file_radius(&file.radius).unwrap_or(base.radius.unwrap_or(8.0)),
            font_prompt: if own("fontPrompt").is_empty() {
                font_ui.clone()
            } else {
                first_font_family(own("fontPrompt"), false, &installed)
            },
            font_terminal: if own("fontTerminal").is_empty() {
                font_mono.clone()
            } else {
                fixed_width(
                    first_font_family(own("fontTerminal"), false, &installed),
                    &installed,
                )
            },
            font_scale: f64::from(size("interface", 16)) / 16.0,
            prompt: size("prompt", 14),
            code: size("code", 13),
            terminal: size("terminal", 12),
            appearance,
            font_ui,
            font_mono,
        }
    }
}

/// "8", "8px" or "0.5rem" (a 16px root).
fn file_radius(value: &str) -> Option<f64> {
    let v = value.trim();
    if v.is_empty() {
        return None;
    }
    if let Some(rem) = v.strip_suffix("rem") {
        return Some(rem.trim().parse::<f64>().unwrap_or(0.0) * 16.0);
    }
    v.strip_suffix("px").unwrap_or(v).trim().parse().ok()
}

/// The theme's CSS font-family list as one family, for a font that falls
/// back on its own: the first non-generic family `installed` has (case
/// aside), else the first non-generic one. With `or_system`, a list that
/// ends in the system's font (`system-ui`) and has nothing installed is
/// empty instead: the system's own font, as CSS resolves it, not a
/// stand-in for a family this machine lacks.
fn first_font_family(list: &str, or_system: bool, installed: &[String]) -> String {
    const GENERIC: [&str; 8] = [
        "system-ui",
        "sans-serif",
        "serif",
        "monospace",
        "ui-sans-serif",
        "ui-monospace",
        "-apple-system",
        "BlinkMacSystemFont",
    ];
    const SYSTEM: [&str; 5] = [
        "system-ui",
        "sans-serif",
        "ui-sans-serif",
        "-apple-system",
        "BlinkMacSystemFont",
    ];
    let families: Vec<&str> = list
        .split(',')
        .map(|f| f.trim().trim_matches(|c| c == '"' || c == '\''))
        .collect();
    let ends_in_system = families.iter().any(|f| SYSTEM.contains(f));
    let candidates: Vec<&str> = families
        .into_iter()
        .filter(|f| !f.is_empty() && !GENERIC.contains(f))
        .collect();
    let is_installed = |f: &&&str| installed.iter().any(|i| i.eq_ignore_ascii_case(f));
    match candidates.iter().find(is_installed) {
        Some(family) => (*family).to_owned(),
        None if or_system && ends_in_system => String::new(),
        None => candidates.first().copied().unwrap_or_default().to_owned(),
    }
}

/// A monospace family as the theme names it, followed by the generic
/// `monospace` when this machine lacks it: Ljós's own stand-in for a missing
/// family is proportional, which spreads a terminal's cells and unaligns
/// code (desktop-qt's `fixedWidth`). Ljós reads a family as a CSS-like list.
fn fixed_width(family: String, installed: &[String]) -> String {
    if family.is_empty() || installed.iter().any(|i| i.eq_ignore_ascii_case(&family)) {
        family
    } else {
        format!("{family}, monospace")
    }
}

/// Sets every property from the file and the base, and tells `palette`'s
/// readers the colours may have changed.
fn show(engine: &Engine) {
    let Ok(obj) = engine.singleton::<ThemeStore>() else {
        return;
    };
    let state = ThemeState::of(engine);
    let file = state.file.borrow();
    let base = state.base.borrow();
    let d = Derived::of(&file, &base);
    let cx = Cx::new(engine, obj);
    let atom = |s: &str| Atom::from(s);
    engine.batch(|| {
        let _ = cx.set(ThemeStore::LOADED, file.loaded);
        let _ = cx.set(ThemeStore::BASE_LOADED, !base.theme.is_null());
        let _ = cx.set(ThemeStore::ID, atom(&file.id));
        let _ = cx.set(ThemeStore::NAME, atom(&file.name));
        let _ = cx.set(ThemeStore::APPEARANCE, atom(&d.appearance));
        let _ = cx.set(
            ThemeStore::FOLLOWS_SYSTEM_APPEARANCE,
            file.follows_system_appearance,
        );
        let _ = cx.set(ThemeStore::LAST_ERROR, atom(&file.last_error));
        let _ = cx.set(ThemeStore::LINK, d.link);
        let _ = cx.set(ThemeStore::RADIUS, d.radius);
        let _ = cx.set(ThemeStore::FONT_UI, atom(&d.font_ui));
        let _ = cx.set(ThemeStore::FONT_MONO, atom(&d.font_mono));
        let _ = cx.set(ThemeStore::FONT_PROMPT, atom(&d.font_prompt));
        let _ = cx.set(ThemeStore::FONT_TERMINAL, atom(&d.font_terminal));
        let _ = cx.set(ThemeStore::FONT_SCALE, d.font_scale);
        let _ = cx.set(ThemeStore::FONT_SIZE_PROMPT, d.prompt);
        let _ = cx.set(ThemeStore::FONT_SIZE_CODE, d.code);
        let _ = cx.set(ThemeStore::FONT_SIZE_TERMINAL, d.terminal);
        let loaded = file.loaded;
        let _ = cx.set(
            ThemeStore::WINDOW_OPACITY,
            if loaded { file.window_opacity } else { 1.0 },
        );
        let _ = cx.set(
            ThemeStore::WINDOW_TRANSPARENT,
            loaded && file.window_transparent,
        );
        let _ = cx.set(ThemeStore::WINDOW_BLUR, loaded && file.window_blur);
        let _ = cx.set(
            ThemeStore::WINDOW_LIQUID_GLASS,
            loaded && file.window_liquid_glass,
        );
        let _ = cx.set(ThemeStore::FRAMELESS, !loaded || file.frameless);
        let _ = cx.notify(ThemeStore::PALETTE.index);
    });
    // ShellRuntime::applyWindowTheme: what the window and the application
    // take from the theme. After the borrows: the platform's answer can run
    // bindings.
    let (loaded, dark) = (file.loaded, d.appearance != "light");
    let (transparent, blur, glass) = (
        file.window_transparent,
        file.window_blur,
        file.window_liquid_glass,
    );
    let follows_system = file.follows_system_appearance;
    drop((d, base, file));
    platform_window::apply_window_theme(
        engine,
        loaded && transparent,
        loaded && blur,
        loaded && glass,
        follows_system,
        dark,
    );
}

#[cfg(test)]
mod tests {
    use super::{first_font_family, fixed_width};

    #[test]
    fn a_font_list_is_its_first_installed_family() {
        let installed = ["IBM Plex Sans".to_owned(), "Inter".to_owned()];
        let first = |list, or_system| first_font_family(list, or_system, &installed);
        assert_eq!(first("Inter", true), "Inter");
        assert_eq!(first("\"IBM Plex Sans\"", true), "IBM Plex Sans");
        // Past a family this machine lacks, and whatever the case.
        assert_eq!(first("\"No Such Family\", inter, system-ui", true), "inter");
        // Nothing installed: the system's font when the list ends in it...
        assert_eq!(first("\"No Such Family\", system-ui, sans-serif", true), "");
        // ...else the first family named, which Ljós falls back from.
        assert_eq!(
            first("\"No Such Family\", system-ui", false),
            "No Such Family"
        );
        assert_eq!(first("'No Such Mono', monospace", false), "No Such Mono");
        assert_eq!(first("monospace", false), "");
    }

    #[test]
    fn a_missing_monospace_family_falls_back_on_a_fixed_width_one() {
        let installed = ["JetBrains Mono".to_owned()];
        let fixed = |family: &str| fixed_width(family.to_owned(), &installed);
        assert_eq!(fixed("jetbrains mono"), "jetbrains mono");
        assert_eq!(fixed("No Such Mono"), "No Such Mono, monospace");
        assert_eq!(fixed(""), "");
    }
}
