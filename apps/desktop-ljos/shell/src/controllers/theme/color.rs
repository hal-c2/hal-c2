//! The colours a theme holds, as desktop-qt reads and grows them: any CSS
//! colour made drawable (`#rrggbb` or `#rrggbbaa`), and the editor's whole
//! palette grown from a canvas and an accent ([`derive`]).
//!
//! Where desktop-qt goes through `QColor::fromRgbF` the channels are kept as
//! Qt keeps them, 16 bits each and read back rounded ([`Rgb`]), so a palette
//! grown here is the one desktop-qt grows, to the byte.

use std::f64::consts::PI;

use serde_json::Map;

use crate::json::Json;

/// A CSS colour as `#rrggbb` (or `#rrggbbaa`): hex as it is, short hex
/// spelled out, `oklch(...)` converted, a named colour as its hex; `None`
/// for what cannot be drawn.
pub fn canonical_color(css: &str) -> Option<String> {
    let value = css.trim().to_lowercase();
    if value.is_empty() || value.encode_utf16().count() > 64 {
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
    if let Some(body) = value
        .strip_prefix("oklch(")
        .and_then(|v| v.strip_suffix(')'))
    {
        return oklch_to_hex(body);
    }
    // QColor reads `alice blue` as `aliceblue`.
    let name: String = value.chars().filter(|c| *c != ' ').collect();
    NAMED
        .binary_search_by(|(known, _)| known.cmp(&name.as_str()))
        .ok()
        .map(|at| format!("#{}", NAMED[at].1))
}

/// The colours of `colors` that can be drawn, made so.
pub fn canonical_colors(colors: &Map<String, Json>) -> Map<String, Json> {
    colors
        .iter()
        .filter_map(|(role, value)| {
            Some((role.clone(), Json::from(canonical_color(value.as_str()?)?)))
        })
        .collect()
}

/// `L C H [/ A]` to sRGB, clipped to the gamut (the CSS Color 4 matrices).
pub fn oklch_to_hex(body: &str) -> Option<String> {
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
    // As desktop-qt converts, to the last bit.
    let h = number(parts[2], 1.0)? * PI / 180.0;
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

/// A colour as QColor keeps one: each channel 16 bits.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rgb([u16; 3]);

impl Rgb {
    /// `#rrggbb`, or the colour part of `#rrggbbaa` (CSS order).
    pub fn parse(hex: &str) -> Option<Rgb> {
        let digits = hex.strip_prefix('#')?;
        if !matches!(digits.len(), 6 | 8) || !digits.bytes().all(|b| b.is_ascii_hexdigit()) {
            return None;
        }
        let byte = |at: usize| u16::from_str_radix(&digits[at..at + 2], 16).ok();
        Some(Rgb([byte(0)? * 257, byte(2)? * 257, byte(4)? * 257]))
    }

    /// `QColor::fromRgbF`, for channels in 0..=1.
    pub fn from_f(r: f64, g: f64, b: f64) -> Rgb {
        let channel = |v: f64| (v.clamp(0.0, 1.0) * 65535.0 + 0.5).floor() as u16;
        Rgb([channel(r), channel(g), channel(b)])
    }

    /// `redF()`, `greenF()`, `blueF()`.
    pub fn f(self) -> [f64; 3] {
        self.0.map(|c| f64::from(c) / 65535.0)
    }

    /// `name()`: `#rrggbb`, each byte read back as Qt rounds it.
    pub fn name(self) -> String {
        let [r, g, b] = self.0.map(qt_byte);
        format!("#{r:02x}{g:02x}{b:02x}")
    }
}

/// A 16-bit channel as the byte Qt reads back (`qt_div_257`).
pub fn qt_byte(channel: u16) -> u8 {
    let x = u32::from(channel);
    ((x - (x >> 8) + 0x80) >> 8) as u8
}

/// A channel in 0..=1 as `setAlphaF` then `alpha()` give it back.
pub fn qt_byte_f(value: f64) -> u8 {
    qt_byte((value.clamp(0.0, 1.0) * 65535.0 + 0.5).floor() as u16)
}

fn linear(channel: f64) -> f64 {
    if channel <= 0.04045 {
        channel / 12.92
    } else {
        ((channel + 0.055) / 1.055).powf(2.4)
    }
}

pub fn luminance(color: Rgb) -> f64 {
    let [r, g, b] = color.f();
    0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
}

pub fn contrast(a: Rgb, b: Rgb) -> f64 {
    let (la, lb) = (luminance(a), luminance(b));
    (la.max(lb) + 0.05) / (la.min(lb) + 0.05)
}

#[derive(Clone, Copy, Debug)]
struct Oklch {
    l: f64,
    c: f64,
    h: f64,
}

fn to_oklch(color: Rgb) -> Oklch {
    let [r, g, b] = color.f().map(linear);
    let l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b).cbrt();
    let m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b).cbrt();
    let s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b).cbrt();
    let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s;
    let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s;
    let mut hue = bb.atan2(a) * 180.0 / PI;
    if hue < 0.0 {
        hue += 360.0;
    }
    Oklch {
        l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        c: a.hypot(bb),
        h: hue,
    }
}

fn from_oklch(color: Oklch) -> Rgb {
    oklch_to_hex(&format!("{:.5} {:.5} {:.3}", color.l, color.c, color.h))
        .and_then(|hex| Rgb::parse(&hex))
        .unwrap_or(Rgb([0; 3]))
}

/// `base` moved lighter or darker until it reads against `against`.
fn solve(mut base: Oklch, against: Rgb, ratio: f64, lighter: bool) -> Rgb {
    let mut color = from_oklch(base);
    let mut step = 0;
    while step < 60 && contrast(color, against) < ratio {
        base.l = (base.l + if lighter { 0.015 } else { -0.015 }).clamp(0.0, 1.0);
        color = from_oklch(base);
        step += 1;
    }
    color
}

pub fn readable_on(surface: Rgb) -> Rgb {
    let light = Rgb([65535; 3]);
    let dark = Rgb([0x11 * 257; 3]);
    if contrast(light, surface) >= contrast(dark, surface) {
        light
    } else {
        dark
    }
}

/// Where white and black text read equally well: a canvas darker than this
/// is a dark one.
pub const DARK_BELOW: f64 = 0.179;

/// A whole palette grown from a canvas and an accent, over `defaults` (the
/// status colours of the canvas's appearance, `dark` when it is a dark
/// one): surfaces step away from the canvas, text is solved for contrast
/// against it. `None` when either is not a colour.
pub fn derive(
    canvas: &str,
    accent: &str,
    defaults: impl FnOnce(bool) -> Map<String, Json>,
) -> Option<Map<String, Json>> {
    let canvas = Rgb::parse(&canonical_color(canvas)?)?;
    let accent = Rgb::parse(&canonical_color(accent)?)?;
    // Follows the canvas picked, not an appearance.
    let dark = luminance(canvas) < DARK_BELOW;
    let base = to_oklch(canvas);
    let tone = to_oklch(accent);
    let hue = if tone.c < 0.02 { base.h } else { tone.h };
    let tint = (tone.c * 0.22).clamp(0.008, 0.045);
    let surface = |delta: f64, chroma: f64| {
        from_oklch(Oklch {
            l: (base.l + if dark { delta } else { -delta }).clamp(0.05, 0.98),
            c: chroma,
            h: hue,
        })
    };
    let text = solve(
        Oklch {
            l: if dark { 0.95 } else { 0.2 },
            c: (tone.c * 0.25).min(0.035),
            h: hue,
        },
        canvas,
        7.0,
        dark,
    );
    let (t, c) = (text.f(), canvas.f());
    let mut text_muted = Rgb::from_f(
        t[0] * 0.65 + c[0] * 0.35,
        t[1] * 0.65 + c[1] * 0.35,
        t[2] * 0.65 + c[2] * 0.35,
    );
    if contrast(text_muted, canvas) < 4.5 {
        text_muted = text;
    }
    let pick = |dark_value: f64, light_value: f64| if dark { dark_value } else { light_value };
    let border = surface(pick(0.16, 0.12), (tone.c * 0.35).min(0.07));
    let input = surface(pick(0.21, 0.16), (tone.c * 0.4).min(0.08));
    let raised = surface(0.05, tint);
    let overlay = surface(0.075, tint);
    let accent_surface = surface(pick(0.13, 0.08), (tone.c * 0.55).min(0.11));
    // The companion action turns off the accent's hue.
    let action_tone = Oklch {
        l: (tone.l + pick(0.06, -0.02)).clamp(0.35, 0.85),
        c: (tone.c * 0.9).max(0.06),
        h: (hue + 50.0) % 360.0,
    };
    let action = from_oklch(action_tone);

    let mut colors = defaults(dark);
    let mut set = |roles: &[&str], color: Rgb| {
        for role in roles {
            colors.insert((*role).to_owned(), Json::from(color.name()));
        }
    };
    set(
        &["canvas", "chrome", "toolbar", "terminalBackground"],
        canvas,
    );
    set(
        &[
            "text",
            "toolbarForeground",
            "toolbarControlForeground",
            "secondaryForeground",
            "accentSurfaceForeground",
            "messageForeground",
            "codeForeground",
            "sidebarForeground",
            "terminalForeground",
        ],
        text,
    );
    set(
        &[
            "textMuted",
            "mutedForeground",
            "placeholder",
            "secondaryLabel",
            "iconMuted",
            "sidebarMutedForeground",
        ],
        text_muted,
    );
    set(
        &[
            "border",
            "toolbarBorder",
            "sidebarBorder",
            "terminalScrollbar",
        ],
        border,
    );
    set(&["accent", "focus", "terminalCursor"], accent);
    set(&["accentForeground"], readable_on(accent));
    set(&["surface"], surface(0.015, tint));
    set(&["surfaceRaised", "toolbarControl"], raised);
    set(&["surfaceOverlay", "toolbarControlHover"], overlay);
    set(&["input", "terminalScrollbarHover"], input);
    set(
        &["secondary"],
        surface(pick(0.1, 0.06), (tone.c * 0.5).min(0.09)),
    );
    set(
        &["muted"],
        surface(pick(0.06, 0.04), (tone.c * 0.35).min(0.06)),
    );
    set(&["accentSurface", "terminalSelection"], accent_surface);
    set(
        &["messageSurface"],
        surface(pick(0.16, 0.1), (tone.c * 0.6).min(0.13)),
    );
    set(&["messageAction"], action);
    set(&["messageActionForeground"], readable_on(action));
    set(
        &["messageActionHover"],
        from_oklch(Oklch {
            l: (action_tone.l + pick(0.05, -0.05)).clamp(0.3, 0.9),
            ..action_tone
        }),
    );
    set(&["codeBackground"], surface(0.035, tint * 0.8));
    set(&["sidebar"], surface(0.045, tint * 1.4));
    set(&["sidebarControlSurface"], surface(0.08, tint));
    set(&["sidebarRowHover"], surface(0.09, tint));
    set(&["sidebarRowActive"], surface(0.12, tint));
    set(&["sidebarRowSelected"], surface(0.14, tint));
    Some(colors)
}

/// The editor's groups of `roles` (the web's ThemeEditorPanel): each role
/// in the first family one of its prefixes starts, else Foundation.
pub fn families(roles: &[String]) -> Json {
    const PREFIXES: [(&str, &[&str]); 3] = [
        ("Status", &["error", "warning", "update"]),
        ("Context", &["sidebar", "terminal"]),
        (
            "Brand & content",
            &["accent", "secondary", "muted", "message", "code", "focus"],
        ),
    ];
    let family = |role: &str| {
        PREFIXES
            .iter()
            .find(|(_, starts)| starts.iter().any(|start| role.starts_with(start)))
            .map_or("Foundation", |(title, _)| title)
    };
    Json::Array(
        ["Foundation", "Brand & content", "Context", "Status"]
            .into_iter()
            .map(|title| {
                let roles: Vec<&String> = roles.iter().filter(|r| family(r) == title).collect();
                serde_json::json!({ "title": title, "roles": roles })
            })
            .collect(),
    )
}

/// The colours `QColor::fromString` names (the SVG ones and
/// `transparent`, drawn as its colour part), sorted for a binary search.
const NAMED: [(&str, &str); 148] = [
    ("aliceblue", "f0f8ff"),
    ("antiquewhite", "faebd7"),
    ("aqua", "00ffff"),
    ("aquamarine", "7fffd4"),
    ("azure", "f0ffff"),
    ("beige", "f5f5dc"),
    ("bisque", "ffe4c4"),
    ("black", "000000"),
    ("blanchedalmond", "ffebcd"),
    ("blue", "0000ff"),
    ("blueviolet", "8a2be2"),
    ("brown", "a52a2a"),
    ("burlywood", "deb887"),
    ("cadetblue", "5f9ea0"),
    ("chartreuse", "7fff00"),
    ("chocolate", "d2691e"),
    ("coral", "ff7f50"),
    ("cornflowerblue", "6495ed"),
    ("cornsilk", "fff8dc"),
    ("crimson", "dc143c"),
    ("cyan", "00ffff"),
    ("darkblue", "00008b"),
    ("darkcyan", "008b8b"),
    ("darkgoldenrod", "b8860b"),
    ("darkgray", "a9a9a9"),
    ("darkgreen", "006400"),
    ("darkgrey", "a9a9a9"),
    ("darkkhaki", "bdb76b"),
    ("darkmagenta", "8b008b"),
    ("darkolivegreen", "556b2f"),
    ("darkorange", "ff8c00"),
    ("darkorchid", "9932cc"),
    ("darkred", "8b0000"),
    ("darksalmon", "e9967a"),
    ("darkseagreen", "8fbc8f"),
    ("darkslateblue", "483d8b"),
    ("darkslategray", "2f4f4f"),
    ("darkslategrey", "2f4f4f"),
    ("darkturquoise", "00ced1"),
    ("darkviolet", "9400d3"),
    ("deeppink", "ff1493"),
    ("deepskyblue", "00bfff"),
    ("dimgray", "696969"),
    ("dimgrey", "696969"),
    ("dodgerblue", "1e90ff"),
    ("firebrick", "b22222"),
    ("floralwhite", "fffaf0"),
    ("forestgreen", "228b22"),
    ("fuchsia", "ff00ff"),
    ("gainsboro", "dcdcdc"),
    ("ghostwhite", "f8f8ff"),
    ("gold", "ffd700"),
    ("goldenrod", "daa520"),
    ("gray", "808080"),
    ("green", "008000"),
    ("greenyellow", "adff2f"),
    ("grey", "808080"),
    ("honeydew", "f0fff0"),
    ("hotpink", "ff69b4"),
    ("indianred", "cd5c5c"),
    ("indigo", "4b0082"),
    ("ivory", "fffff0"),
    ("khaki", "f0e68c"),
    ("lavender", "e6e6fa"),
    ("lavenderblush", "fff0f5"),
    ("lawngreen", "7cfc00"),
    ("lemonchiffon", "fffacd"),
    ("lightblue", "add8e6"),
    ("lightcoral", "f08080"),
    ("lightcyan", "e0ffff"),
    ("lightgoldenrodyellow", "fafad2"),
    ("lightgray", "d3d3d3"),
    ("lightgreen", "90ee90"),
    ("lightgrey", "d3d3d3"),
    ("lightpink", "ffb6c1"),
    ("lightsalmon", "ffa07a"),
    ("lightseagreen", "20b2aa"),
    ("lightskyblue", "87cefa"),
    ("lightslategray", "778899"),
    ("lightslategrey", "778899"),
    ("lightsteelblue", "b0c4de"),
    ("lightyellow", "ffffe0"),
    ("lime", "00ff00"),
    ("limegreen", "32cd32"),
    ("linen", "faf0e6"),
    ("magenta", "ff00ff"),
    ("maroon", "800000"),
    ("mediumaquamarine", "66cdaa"),
    ("mediumblue", "0000cd"),
    ("mediumorchid", "ba55d3"),
    ("mediumpurple", "9370db"),
    ("mediumseagreen", "3cb371"),
    ("mediumslateblue", "7b68ee"),
    ("mediumspringgreen", "00fa9a"),
    ("mediumturquoise", "48d1cc"),
    ("mediumvioletred", "c71585"),
    ("midnightblue", "191970"),
    ("mintcream", "f5fffa"),
    ("mistyrose", "ffe4e1"),
    ("moccasin", "ffe4b5"),
    ("navajowhite", "ffdead"),
    ("navy", "000080"),
    ("oldlace", "fdf5e6"),
    ("olive", "808000"),
    ("olivedrab", "6b8e23"),
    ("orange", "ffa500"),
    ("orangered", "ff4500"),
    ("orchid", "da70d6"),
    ("palegoldenrod", "eee8aa"),
    ("palegreen", "98fb98"),
    ("paleturquoise", "afeeee"),
    ("palevioletred", "db7093"),
    ("papayawhip", "ffefd5"),
    ("peachpuff", "ffdab9"),
    ("peru", "cd853f"),
    ("pink", "ffc0cb"),
    ("plum", "dda0dd"),
    ("powderblue", "b0e0e6"),
    ("purple", "800080"),
    ("red", "ff0000"),
    ("rosybrown", "bc8f8f"),
    ("royalblue", "4169e1"),
    ("saddlebrown", "8b4513"),
    ("salmon", "fa8072"),
    ("sandybrown", "f4a460"),
    ("seagreen", "2e8b57"),
    ("seashell", "fff5ee"),
    ("sienna", "a0522d"),
    ("silver", "c0c0c0"),
    ("skyblue", "87ceeb"),
    ("slateblue", "6a5acd"),
    ("slategray", "708090"),
    ("slategrey", "708090"),
    ("snow", "fffafa"),
    ("springgreen", "00ff7f"),
    ("steelblue", "4682b4"),
    ("tan", "d2b48c"),
    ("teal", "008080"),
    ("thistle", "d8bfd8"),
    ("tomato", "ff6347"),
    ("transparent", "000000"),
    ("turquoise", "40e0d0"),
    ("violet", "ee82ee"),
    ("wheat", "f5deb3"),
    ("white", "ffffff"),
    ("whitesmoke", "f5f5f5"),
    ("yellow", "ffff00"),
    ("yellowgreen", "9acd32"),
];
