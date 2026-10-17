//! `theme`, desktop-qt's ThemeController: the look the shell resolves from
//! the appearance mode (system, light or dark), which `Theme` draws from.
//!
//! Not ported yet: saved and published themes, theme halves, the editor,
//! the Appearance settings (diff colours, glass, font rows), keeping the mode
//! in the device preferences, the cycle's toast, and following the system
//! scheme as it changes (it is read when the look resolves).

use std::sync::OnceLock;

use ljos::prelude::Engine;
use serde_json::{Map, json};

use crate::bridge::Bridge;
use crate::controller::{Controller, Init};
use crate::json::Json;

/// What the standard look is published as.
pub const STANDARD_ID: &str = "hal-c2";

/// themes.json as desktop-qt builds it in, its colours made drawable once.
struct BuiltIns {
    light: Map<String, Json>,
    dark: Map<String, Json>,
    fixed_light: Map<String, Json>,
    fixed_dark: Map<String, Json>,
    radius: Json,
    font_ui: String,
    font_mono: String,
}

fn built_ins() -> &'static BuiltIns {
    static DATA: OnceLock<BuiltIns> = OnceLock::new();
    DATA.get_or_init(|| {
        let root: Json = serde_json::from_str(include_str!(
            "../../../../desktop-qt/src/native/themes.json"
        ))
        .expect("themes.json is JSON");
        let colors = |path: &[&str]| {
            let value = path.iter().fold(&root, |v, key| &v[*key]);
            canonical_colors(value.as_object().cloned().unwrap_or_default())
        };
        BuiltIns {
            light: colors(&["standard", "light"]),
            dark: colors(&["standard", "dark"]),
            fixed_light: colors(&["fixed", "light"]),
            fixed_dark: colors(&["fixed", "dark"]),
            radius: root.get("radius").cloned().unwrap_or(json!(10)),
            font_ui: root["fonts"]["ui"].as_str().unwrap_or_default().to_owned(),
            font_mono: root["fonts"]["mono"]
                .as_str()
                .unwrap_or_default()
                .to_owned(),
        }
    })
}

fn canonical_colors(colors: Map<String, Json>) -> Map<String, Json> {
    colors
        .into_iter()
        .filter_map(|(role, value)| Some((role, Json::from(canonical_color(value.as_str()?)?))))
        .collect()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    System,
    Light,
    Dark,
}

impl Mode {
    pub fn parse(mode: &str) -> Option<Mode> {
        match mode {
            "system" => Some(Mode::System),
            "light" => Some(Mode::Light),
            "dark" => Some(Mode::Dark),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Mode::System => "system",
            Mode::Light => "light",
            Mode::Dark => "dark",
        }
    }
}

pub struct Themes {
    bridge: Bridge,
    mode: Mode,
    /// The appearance the look resolved to.
    appearance: &'static str,
}

impl Controller for Themes {
    // The look needs no MC: it shows before the first snapshot.
    fn new(init: Init<'_, Self>) -> Self {
        let mut themes = Themes {
            bridge: init.bridge,
            mode: Mode::System,
            appearance: "dark",
        };
        themes.resolve(init.engine);
        themes
    }

    fn activate(&mut self, engine: &Engine) {
        self.resolve(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        match action {
            "appearance.cycle" => self.cycle(engine),
            "theme.mode" => {
                if let Some(mode) = payload
                    .get("mode")
                    .and_then(Json::as_str)
                    .and_then(Mode::parse)
                {
                    self.set_mode(engine, mode);
                }
            }
            _ => return false,
        }
        true
    }
}

impl Themes {
    pub fn mode(&self) -> Mode {
        self.mode
    }

    pub fn appearance(&self) -> &'static str {
        self.appearance
    }

    /// system, then light, then dark, then system again.
    pub fn cycle(&mut self, engine: &Engine) {
        let next = match self.mode {
            Mode::System => Mode::Light,
            Mode::Light => Mode::Dark,
            Mode::Dark => Mode::System,
        };
        self.set_mode(engine, next);
    }

    pub fn set_mode(&mut self, engine: &Engine, mode: Mode) {
        self.mode = mode;
        self.resolve(engine);
    }

    fn resolve(&mut self, engine: &Engine) {
        let data = built_ins();
        let dark = match self.mode {
            Mode::Dark => true,
            Mode::Light => false,
            Mode::System => ljos::color_scheme(engine) == ljos::prelude::ColorScheme::Dark,
        };
        let (standard, fixed) = if dark {
            (&data.dark, &data.fixed_dark)
        } else {
            (&data.light, &data.fixed_light)
        };
        let mut colors = standard.clone();
        for (role, color) in fixed {
            colors.entry(role.clone()).or_insert_with(|| color.clone());
        }
        colors.insert("diffAdded".into(), json!("#22c55e"));
        colors.insert("diffRemoved".into(), json!("#ef4444"));
        self.appearance = if dark { "dark" } else { "light" };
        self.bridge.publish(
            engine,
            "theme",
            json!({
                "id": STANDARD_ID,
                "appearance": self.appearance,
                "colors": colors,
                "radius": data.radius,
                "fontUi": data.font_ui,
                "fontMono": data.font_mono,
                // Empty: the composer writes in the interface font, the
                // terminal in the code font.
                "fontPrompt": "",
                "fontTerminal": "",
                "fontSizes": {"interface": 16, "prompt": 14, "code": 13, "terminal": 12},
            }),
        );
    }
}

/// A CSS colour as `#rrggbb` (or `#rrggbbaa`): hex as it is, short hex
/// spelled out, `oklch(...)` converted; `None` for what cannot be drawn.
/// Named colours are not read (the built-in themes use none).
pub fn canonical_color(css: &str) -> Option<String> {
    let value = css.trim().to_ascii_lowercase();
    if value.is_empty() || value.len() > 64 {
        return None;
    }
    if let Some(hex) = value.strip_prefix('#') {
        if !matches!(hex.len(), 3 | 4 | 6 | 8) || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
            return None;
        }
        if hex.len() > 4 {
            return Some(value);
        }
        return Some(
            std::iter::once('#')
                .chain(hex.chars().flat_map(|d| [d, d]))
                .collect(),
        );
    }
    value
        .strip_prefix("oklch(")?
        .strip_suffix(')')
        .and_then(oklch_to_hex)
}

/// `L C H [/ A]` to sRGB, clipped to the gamut (the CSS Color 4 matrices).
fn oklch_to_hex(body: &str) -> Option<String> {
    let parts: Vec<&str> = body
        .split(|c: char| c.is_whitespace() || c == ',' || c == '/')
        .filter(|p| !p.is_empty())
        .collect();
    if !(3..=4).contains(&parts.len()) {
        return None;
    }
    let number = |text: &str, percent: f64| -> Option<f64> {
        if text == "none" {
            return Some(0.0);
        }
        if let Some(n) = text.strip_suffix('%') {
            return n.parse::<f64>().ok().map(|n| n * percent);
        }
        text.strip_suffix("deg").unwrap_or(text).parse().ok()
    };
    let l = number(parts[0], 0.01)?;
    let c = number(parts[1], 0.004)?;
    let h = number(parts[2], 1.0)?.to_radians();
    let alpha = match parts.get(3) {
        Some(a) => number(a, 0.01)?,
        None => 1.0,
    };
    let (a, b) = (c * h.cos(), c * h.sin());
    let l_ = (l + 0.3963377774 * a + 0.2158037573 * b).powi(3);
    let m_ = (l - 0.1055613458 * a - 0.0638541728 * b).powi(3);
    let s_ = (l - 0.0894841775 * a - 1.2914855480 * b).powi(3);
    let gamma = |linear: f64| {
        let linear = linear.clamp(0.0, 1.0);
        if linear <= 0.0031308 {
            12.92 * linear
        } else {
            1.055 * linear.powf(1.0 / 2.4) - 0.055
        }
    };
    let byte = |channel: f64| format!("{:02x}", (channel * 255.0).round().clamp(0.0, 255.0) as u8);
    let mut hex = format!(
        "#{}{}{}",
        byte(gamma(
            4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_
        )),
        byte(gamma(
            -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_
        )),
        byte(gamma(
            -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_
        )),
    );
    if alpha < 1.0 {
        hex += &byte(alpha.clamp(0.0, 1.0));
    }
    Some(hex)
}
