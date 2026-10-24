//! Theme files in: desktop-qt's reading of one (version 1, or a VS Code
//! colour theme converted on the way in), its id rules, and the size limit.

use serde_json::{Map, json};

use super::color::{Rgb, canonical_color, contrast, derive, luminance};
use super::{BuiltIns, built_ins, int_of, left_utf16, object_of, string_of, utf16_len};
use crate::json::Json;

/// A theme file larger than this is not read: they are a few KB.
pub const MAX_THEME_FILE_BYTES: u64 = 256 * 1024;

/// A theme's id from its name: lowercase letters and digits, runs of
/// anything else one dash.
pub fn id_from_name(name: &str) -> String {
    let mut id = String::new();
    let mut dash = false;
    for c in name.trim().to_lowercase().chars() {
        if c.is_ascii_lowercase() || c.is_ascii_digit() {
            if dash && !id.is_empty() {
                id.push('-');
            }
            dash = false;
            id.push(c);
        } else {
            dash = true;
        }
    }
    let id = left_utf16(&id, 48).to_owned();
    if id.is_empty() {
        "custom-theme".to_owned()
    } else {
        id
    }
}

fn byte_size(bytes: u64) -> String {
    if bytes >= 1024 * 1024 {
        format!("{:.1} MB", bytes as f64 / (1024.0 * 1024.0))
    } else {
        format!("{} KB", (bytes / 1024).max(1))
    }
}

/// Why a file of `bytes` is not read, or `None` when it may be.
pub fn oversized(bytes: u64) -> Option<String> {
    (bytes > MAX_THEME_FILE_BYTES).then(|| {
        format!(
            "That file is {}. Theme files are only a few KB, so this one was not read (limit {}).",
            byte_size(bytes),
            byte_size(MAX_THEME_FILE_BYTES)
        )
    })
}

/// The palette a theme file gives, over `base`: roles this build knows, in
/// colours it can draw.
pub fn overlay(mut base: Map<String, Json>, colors: &Map<String, Json>) -> Map<String, Json> {
    let roles = &built_ins().roles;
    for (role, value) in colors {
        if !roles.contains(role) {
            continue;
        }
        if let Some(color) = canonical_color(string_of(value)) {
            base.insert(role.clone(), Json::from(color));
        }
    }
    base
}

fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && !id.starts_with('-')
        && !id.ends_with('-')
        && !id.contains("--")
        && id
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

fn valid_collection_id(id: &str) -> bool {
    let mut chars = id.chars();
    chars.next().is_some_and(|c| c.is_ascii_alphanumeric())
        && id.len() <= 128
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | ':' | '-'))
}

/// A theme file's theme (`id`, `label`, `appearance`, `colors`, and
/// `variants` and `collection` when it has them), or why it cannot be read.
pub fn parse_file(text: &[u8]) -> Result<Map<String, Json>, String> {
    let data = built_ins();
    let Ok(document) = serde_json::from_slice::<Json>(text) else {
        return Err("That theme file is invalid.".to_owned());
    };
    let Json::Object(mut file) = document else {
        return Err("Theme files must contain a JSON object.".to_owned());
    };
    // A VS Code colour theme is converted on the way in.
    if is_vs_code_theme(&file) {
        file = from_vs_code_theme(&file, data)?;
    }
    if int_of(file.get("version")) != 1 {
        return Err("This theme file uses an unsupported version. Expected 1.".to_owned());
    }
    let name = string_of(file.get("name").unwrap_or(&Json::Null)).trim();
    if name.is_empty() || utf16_len(name) > 48 {
        return Err("Theme files need a name (48 characters or fewer).".to_owned());
    }
    let appearance = string_of(file.get("appearance").unwrap_or(&Json::Null));
    if appearance != "light" && appearance != "dark" {
        return Err("Theme files need an appearance of \"light\" or \"dark\".".to_owned());
    }
    let Some(Json::Object(colors)) = file.get("colors") else {
        return Err("Theme files need a colors object.".to_owned());
    };
    let id = match file.get("id") {
        Some(id) => string_of(id).to_owned(),
        None => id_from_name(name),
    };
    if utf16_len(&id) > 48 || !valid_id(&id) {
        return Err(
            "Theme ids may only contain lowercase letters, numbers, and hyphens.".to_owned(),
        );
    }
    if data.reserved.contains(&id)
        || id == super::STANDARD_ID
        || data.themes.iter().any(|t| string_of(&t["id"]) == id)
    {
        return Err(format!("The theme id \"{id}\" is reserved."));
    }
    let mut theme = Map::new();
    theme.insert("id".into(), json!(id));
    theme.insert("label".into(), json!(name));
    theme.insert("appearance".into(), json!(appearance));
    theme.insert("colors".into(), Json::Object(overlay(Map::new(), colors)));
    let mut variants = Map::new();
    // In key order, as desktop-qt meets them.
    for (key, value) in object_of(file.get("variants")) {
        if key != "light" && key != "dark" {
            return Err("Theme variants may only be named \"light\" or \"dark\".".to_owned());
        }
        if key == appearance {
            return Err(format!(
                "Theme variants must not repeat the base appearance \"{appearance}\"."
            ));
        }
        let colors = overlay(Map::new(), &object_of(Some(&value)));
        variants.insert(key, Json::Object(colors));
    }
    if !variants.is_empty() {
        theme.insert("variants".into(), Json::Object(variants));
    }
    // The family it was installed with (an extension's themes).
    if file.contains_key("collection") {
        let collection = object_of(file.get("collection"));
        let collection_id = collection.get("id").cloned().unwrap_or(Json::Null);
        let label = string_of(collection.get("label").unwrap_or(&Json::Null)).trim();
        if !valid_collection_id(string_of(&collection_id))
            || label.is_empty()
            || utf16_len(label) > 48
        {
            return Err("Theme collections need a valid id and label.".to_owned());
        }
        theme.insert(
            "collection".into(),
            json!({ "id": collection_id, "label": label }),
        );
    }
    Ok(theme)
}

// --- VS Code themes ---------------------------------------------------------

#[derive(Clone, Copy, Default)]
struct VsColor {
    r: f64,
    g: f64,
    b: f64,
    a: f64,
}

impl VsColor {
    fn solid(self) -> Rgb {
        Rgb::from_f(self.r, self.g, self.b)
    }
}

/// VS Code writes #RGB, #RGBA, #RRGGBB and #RRGGBBAA, the `#` optional.
fn vs_color(value: Option<&Json>) -> Option<VsColor> {
    let text = string_of(value.unwrap_or(&Json::Null)).trim();
    let digits = text.strip_prefix('#').unwrap_or(text);
    if !matches!(digits.len(), 3 | 4 | 6 | 8) || !digits.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let digits: String = if digits.len() <= 4 {
        digits.chars().flat_map(|d| [d, d]).collect()
    } else {
        digits.to_owned()
    };
    let channel =
        |at: usize| f64::from(u8::from_str_radix(&digits[at..at + 2], 16).unwrap_or(0)) / 255.0;
    Some(VsColor {
        r: channel(0),
        g: channel(2),
        b: channel(4),
        a: if digits.len() == 8 { channel(6) } else { 1.0 },
    })
}

/// Overlays are translucent in VS Code and our roles are opaque: over the
/// surface they sit on.
fn flattened(color: VsColor, base: Rgb) -> String {
    let [r, g, b] = base.f();
    let a = color.a;
    Rgb::from_f(
        color.r * a + r * (1.0 - a),
        color.g * a + g * (1.0 - a),
        color.b * a + b * (1.0 - a),
    )
    .name()
}

/// Extension names are often package slugs; read them as words.
fn humanized(raw: &str) -> String {
    let trimmed = raw.trim();
    let space = |c: char| matches!(c, ' ' | '\t' | '\n' | '\x0b' | '\x0c' | '\r');
    let separator = |c: char| matches!(c, '-' | '_' | '.');
    if trimmed.contains(space) || !trimmed.contains(separator) {
        return trimmed.to_owned();
    }
    trimmed
        .split(separator)
        .filter(|word| !word.is_empty())
        .map(|word| {
            let mut chars = word.chars();
            chars
                .next()
                .map(|first| first.to_uppercase().chain(chars).collect::<String>())
                .unwrap_or_default()
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Its workbench colours are dotted paths (`editor.background`), which our
/// own files never use.
fn is_vs_code_theme(file: &Map<String, Json>) -> bool {
    if int_of(file.get("version")) == 1 {
        return false;
    }
    if file.get("tokenColors").is_some_and(Json::is_array) {
        return true;
    }
    object_of(file.get("colors"))
        .keys()
        .any(|key| key.contains('.'))
}

fn hex_color(hex: &str) -> Rgb {
    Rgb::parse(hex).unwrap_or(Rgb::from_f(0.0, 0.0, 0.0))
}

/// A VS Code theme describes editor chrome, not an app palette: a whole
/// palette is grown from its editor background and a muted accent
/// ([`derive`]), then the workbench colours it does set go on top,
/// foregrounds only where they stay readable. The result is one of our
/// theme files. Batches are not paired into light and dark here.
fn from_vs_code_theme(
    file: &Map<String, Json>,
    data: &BuiltIns,
) -> Result<Map<String, Json>, String> {
    let colors = object_of(file.get("colors"));
    let pick = |keys: &[&str]| keys.iter().find_map(|key| vs_color(colors.get(*key)));
    let Some(canvas_color) = pick(&["editor.background", "editorPane.background"]) else {
        return Err("That VS Code theme has no \"editor.background\" color, so there is nothing to build a palette from.".to_owned());
    };
    let canvas = canvas_color.solid();
    let kind = string_of(file.get("type").unwrap_or(&Json::Null)).to_lowercase();
    let appearance = match kind.as_str() {
        "light" | "hc-light" => "light",
        "dark" | "hc-black" => "dark",
        _ if luminance(canvas) < super::color::DARK_BELOW => "dark",
        _ => "light",
    };
    let accent_color = pick(&[
        "focusBorder",
        "button.background",
        "textLink.foreground",
        "activityBarBadge.background",
        "progressBar.background",
        "badge.background",
    ]);
    let canvas_hex = canvas.name();
    // The floor grows from a muted accent, so a neutral theme is not washed
    // in its focus colour.
    let floor = accent_color.map_or_else(
        || canvas_hex.clone(),
        |accent| flattened(VsColor { a: 0.2, ..accent }, canvas),
    );
    let mut palette = derive(&canvas_hex, &floor, |dark| {
        object_of(data.defaults.get(if dark { "dark" } else { "light" }))
    })
    .unwrap_or_default();
    let derived = |palette: &Map<String, Json>, role: &str| {
        string_of(palette.get(role).unwrap_or(&Json::Null)).to_owned()
    };
    let solid_over = |base: Rgb, keys: &[&str]| pick(keys).map(|color| flattened(color, base));
    let or_derived =
        |value: Option<String>, role: &str| value.unwrap_or_else(|| derived(&palette, role));
    let readable = |palette: &Map<String, Json>, surface: &str, role: &str, keys: &[&str]| {
        let on = hex_color(surface);
        let reads = |candidate: &str| contrast(hex_color(candidate), on) >= 4.5;
        if let Some(named) = solid_over(on, keys).filter(|named| reads(named)) {
            return named;
        }
        let fallback = derived(palette, role);
        if reads(&fallback) {
            return fallback;
        }
        if luminance(on) < super::color::DARK_BELOW {
            "#ffffff".to_owned()
        } else {
            "#000000".to_owned()
        }
    };
    let status = |role: &str, keys: &[&str]| {
        solid_over(canvas, keys)
            .filter(|named| contrast(hex_color(named), canvas) >= 4.5)
            .unwrap_or_else(|| derived(&palette, role))
    };
    let sidebar_hex = or_derived(
        solid_over(canvas, &["sideBar.background", "activityBar.background"]),
        "sidebar",
    );
    let sidebar = hex_color(&sidebar_hex);
    let terminal_hex = or_derived(
        solid_over(canvas, &["terminal.background", "panel.background"]),
        "terminalBackground",
    );
    let terminal = hex_color(&terminal_hex);
    let p = &palette;
    let overrides = [
        ("canvas", canvas_hex.clone()),
        (
            "text",
            readable(p, &canvas_hex, "text", &["editor.foreground", "foreground"]),
        ),
        (
            "textMuted",
            readable(
                p,
                &canvas_hex,
                "textMuted",
                &["descriptionForeground", "disabledForeground"],
            ),
        ),
        (
            "surface",
            or_derived(solid_over(canvas, &["editorWidget.background"]), "surface"),
        ),
        (
            "surfaceRaised",
            or_derived(
                solid_over(canvas, &["editorWidget.background", "dropdown.background"]),
                "surfaceRaised",
            ),
        ),
        (
            "surfaceOverlay",
            or_derived(
                solid_over(
                    canvas,
                    &[
                        "menu.background",
                        "quickInput.background",
                        "dropdown.background",
                    ],
                ),
                "surfaceOverlay",
            ),
        ),
        (
            "border",
            or_derived(
                solid_over(
                    canvas,
                    &["panel.border", "editorGroup.border", "contrastBorder"],
                ),
                "border",
            ),
        ),
        (
            "input",
            or_derived(
                solid_over(canvas, &["input.border", "dropdown.border"]),
                "input",
            ),
        ),
        (
            "placeholder",
            readable(
                p,
                &canvas_hex,
                "placeholder",
                &["input.placeholderForeground"],
            ),
        ),
        // The status colours stay the standard ones unless the theme's own
        // read here.
        (
            "error",
            status("error", &["editorError.foreground", "errorForeground"]),
        ),
        ("warning", status("warning", &["editorWarning.foreground"])),
        (
            "accentSurface",
            or_derived(
                solid_over(
                    canvas,
                    &["list.activeSelectionBackground", "list.hoverBackground"],
                ),
                "accentSurface",
            ),
        ),
        (
            "codeBackground",
            or_derived(
                solid_over(canvas, &["textCodeBlock.background"]),
                "codeBackground",
            ),
        ),
        ("sidebar", sidebar_hex.clone()),
        (
            "sidebarForeground",
            readable(
                p,
                &sidebar_hex,
                "sidebarForeground",
                &["sideBar.foreground"],
            ),
        ),
        (
            "sidebarBorder",
            or_derived(solid_over(sidebar, &["sideBar.border"]), "sidebarBorder"),
        ),
        (
            "sidebarRowHover",
            or_derived(
                solid_over(sidebar, &["list.hoverBackground"]),
                "sidebarRowHover",
            ),
        ),
        (
            "sidebarRowActive",
            or_derived(
                solid_over(
                    sidebar,
                    &["list.inactiveSelectionBackground", "list.hoverBackground"],
                ),
                "sidebarRowActive",
            ),
        ),
        (
            "sidebarRowSelected",
            or_derived(
                solid_over(sidebar, &["list.activeSelectionBackground"]),
                "sidebarRowSelected",
            ),
        ),
        ("terminalBackground", terminal_hex.clone()),
        (
            "terminalForeground",
            readable(
                p,
                &terminal_hex,
                "terminalForeground",
                &["terminal.foreground"],
            ),
        ),
        (
            "terminalCursor",
            or_derived(
                solid_over(
                    terminal,
                    &["terminalCursor.foreground", "editorCursor.foreground"],
                ),
                "terminalCursor",
            ),
        ),
        (
            "terminalSelection",
            or_derived(
                solid_over(
                    terminal,
                    &["terminal.selectionBackground", "editor.selectionBackground"],
                ),
                "terminalSelection",
            ),
        ),
        (
            "terminalScrollbar",
            or_derived(
                solid_over(terminal, &["scrollbarSlider.background"]),
                "terminalScrollbar",
            ),
        ),
    ];
    for (role, value) in overrides {
        palette.insert(role.to_owned(), Json::from(value));
    }
    if let Some(accent) = accent_color {
        let accent_hex = flattened(accent, canvas);
        // The button pair is the closest thing VS Code has to our action
        // colour.
        let action_hex = solid_over(canvas, &["button.background"]).unwrap_or(accent_hex.clone());
        let action_foreground = readable(
            &palette,
            &action_hex,
            "messageActionForeground",
            &["button.foreground"],
        );
        let accent_foreground = readable(
            &palette,
            &accent_hex,
            "accentForeground",
            &["button.foreground"],
        );
        palette.insert("accent".into(), json!(accent_hex));
        palette.insert("focus".into(), json!(accent_hex));
        palette.insert("messageAction".into(), json!(action_hex));
        palette.insert("messageActionForeground".into(), json!(action_foreground));
        palette.insert("accentForeground".into(), json!(accent_foreground));
    }
    let name = ["displayName", "name"]
        .iter()
        .filter_map(|key| file.get(*key)?.as_str().map(humanized))
        .find(|name| !name.is_empty())
        .map_or_else(
            || "VS Code theme".to_owned(),
            |name| left_utf16(&name, 48).to_owned(),
        );
    Ok(json!({
        "version": 1,
        "name": name,
        "appearance": appearance,
        "colors": palette,
    })
    .as_object()
    .cloned()
    .unwrap_or_default())
}
