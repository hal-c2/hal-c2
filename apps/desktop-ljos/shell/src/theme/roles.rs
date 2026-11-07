//! How a role's colour resolves (desktop-qt's `ThemeStore::color`): a role
//! a palette lacks is read from the older role it renames (`ink` is `text`)
//! or derived from roles it has (`inkSecondary` between `ink` and
//! `inkTertiary`), so themes written before a role existed still draw it in
//! their own colours.

use ljos::prelude::Color;

use super::parse_css_color;
use crate::json::Json;

pub type Palette = serde_json::Map<String, Json>;

/// The other name of a role that has two: a newer one and the one themes
/// already set.
fn renamed(role: &str) -> Option<&'static str> {
    Some(match role {
        "ink" => "text",
        "text" => "ink",
        "inkTertiary" => "textMuted",
        "textMuted" => "inkTertiary",
        "destructive" => "error",
        "error" => "destructive",
        "popover" => "surfaceOverlay",
        "surfaceOverlay" => "popover",
        _ => return None,
    })
}

/// A role derived from others when a palette leaves it out: `a` mixed
/// `amount` of the way to `b`, or a copy of `a` (no `b`).
struct Derivation {
    a: &'static str,
    b: Option<&'static str>,
    amount: f64,
}

fn derivation(role: &str) -> Option<Derivation> {
    let (a, b, amount) = match role {
        "inkSecondary" => ("ink", Some("inkTertiary"), 0.5),
        "borderStrong" => ("border", Some("ink"), 0.12),
        "inset" => ("codeBackground", None, 0.0),
        "inputSurface" => ("surface", None, 0.0),
        "accentText" => ("accent", None, 0.0),
        "diffAddedSurface" => ("canvas", Some("diffAdded"), 0.14),
        "diffRemovedSurface" => ("canvas", Some("diffRemoved"), 0.14),
        _ => return None,
    };
    Some(Derivation { a, b, amount })
}

/// A role a palette names, under either of its names.
fn named(palette: &Palette, role: &str) -> Option<Color> {
    let own = |role: &str| {
        palette
            .get(role)
            .and_then(Json::as_str)
            .and_then(parse_css_color)
    };
    own(role).or_else(|| renamed(role).and_then(own))
}

fn derive(recipe: &Derivation, lookup: impl Fn(&str) -> Option<Color>) -> Option<Color> {
    let first = lookup(recipe.a)?;
    match recipe.b {
        None => Some(first),
        Some(b) => Some(mix(first, lookup(b)?, recipe.amount)),
    }
}

/// A role in one palette alone: named, or derived from what it names.
fn resolve_in(palette: &Palette, role: &str) -> Option<Color> {
    named(palette, role).or_else(|| derive(&derivation(role)?, |r| named(palette, r)))
}

/// A role's colour: the shell's theme file (`shell`) first, then the base
/// theme. A derived role the file leaves out still follows the file when it
/// sets what the role is made of: its own text, say, gives its own secondary
/// ink. `None` where neither has it.
pub fn resolve(shell: &Palette, base: &Palette, light: bool, role: &str) -> Option<Color> {
    if let Some(own) = named(shell, role) {
        return Some(own);
    }
    let destructive_fill = role == "destructiveFill";
    if destructive_fill && let Some(error) = named(shell, "error") {
        return Some(deepened_under_white(error));
    }
    if let Some(recipe) = derivation(role)
        && (named(shell, recipe.a).is_some() || recipe.b.is_some_and(|b| named(shell, b).is_some()))
        && let Some(derived) = derive(&recipe, |r| resolve(shell, base, light, r))
    {
        return Some(derived);
    }
    if let Some(found) = resolve_in(base, role) {
        return Some(found);
    }
    if destructive_fill && let Some(error) = resolve_in(base, "error") {
        return Some(deepened_under_white(error));
    }
    // What dims the window behind a dialog, when no palette says.
    (role == "scrim").then(|| {
        if light {
            Color::from_rgba8(0x14, 0x16, 0x1a, 82)
        } else {
            Color::from_rgba8(0, 0, 0, 143)
        }
    })
}

fn mix(from: Color, to: Color, amount: f64) -> Color {
    let (f, t) = (from.to_rgba_f(), to.to_rgba_f());
    let at = |i: usize| f[i] + (t[i] - f[i]) * amount;
    Color::from_rgba_f(at(0), at(1), at(2), at(3))
}

/// `color` deepened until white text on it reads at 4.5:1 (WCAG AA): what a
/// destructive button is filled with when no palette names destructiveFill.
fn deepened_under_white(color: Color) -> Color {
    let channel = |c: f64| {
        if c <= 0.04045 {
            c / 12.92
        } else {
            ((c + 0.055) / 1.055).powf(2.4)
        }
    };
    let contrast = |[r, g, b]: [f64; 3]| {
        1.05 / (0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b) + 0.05)
    };
    let [r, g, b, _] = color.to_rgba_f();
    let (hue, saturation, mut lightness) = to_hsl(r, g, b);
    let mut fill = [r, g, b];
    while lightness > 0.0 && contrast(fill) < 4.5 {
        lightness = (lightness - 0.01).max(0.0);
        fill = from_hsl(hue, saturation, lightness);
    }
    Color::from_rgba_f(fill[0], fill[1], fill[2], 1.0)
}

/// Hue (0..1, 0 for a grey), saturation and lightness.
fn to_hsl(r: f64, g: f64, b: f64) -> (f64, f64, f64) {
    let (max, min) = (r.max(g).max(b), r.min(g).min(b));
    let lightness = (max + min) / 2.0;
    let delta = max - min;
    if delta == 0.0 {
        return (0.0, 0.0, lightness);
    }
    let saturation = delta / (1.0 - (2.0 * lightness - 1.0).abs());
    let sector = if max == r {
        ((g - b) / delta).rem_euclid(6.0)
    } else if max == g {
        (b - r) / delta + 2.0
    } else {
        (r - g) / delta + 4.0
    };
    (sector / 6.0, saturation, lightness)
}

fn from_hsl(hue: f64, saturation: f64, lightness: f64) -> [f64; 3] {
    let chroma = (1.0 - (2.0 * lightness - 1.0).abs()) * saturation;
    let sector = hue * 6.0;
    let x = chroma * (1.0 - (sector.rem_euclid(2.0) - 1.0).abs());
    let (r, g, b) = match sector as u32 {
        0 => (chroma, x, 0.0),
        1 => (x, chroma, 0.0),
        2 => (0.0, chroma, x),
        3 => (0.0, x, chroma),
        4 => (x, 0.0, chroma),
        _ => (chroma, 0.0, x),
    };
    let m = lightness - chroma / 2.0;
    [r + m, g + m, b + m]
}

#[cfg(test)]
mod tests {
    use super::{Palette, resolve};
    use crate::json::Json;
    use ljos::prelude::Color;

    fn palette(pairs: &[(&str, &str)]) -> Palette {
        pairs
            .iter()
            .map(|(k, v)| ((*k).to_owned(), Json::String((*v).to_owned())))
            .collect()
    }

    fn hex(color: Option<Color>) -> Option<[u8; 4]> {
        color.map(Color::to_rgba8)
    }

    #[test]
    fn a_renamed_role_reads_its_old_name() {
        let base = palette(&[("text", "#102030"), ("error", "#ff0000")]);
        let none = Palette::new();
        assert_eq!(
            hex(resolve(&none, &base, false, "ink")),
            Some([0x10, 0x20, 0x30, 255])
        );
        assert_eq!(
            hex(resolve(&none, &base, false, "destructive")),
            Some([255, 0, 0, 255])
        );
    }

    #[test]
    fn a_derived_role_follows_the_file_that_sets_what_it_is_made_of() {
        let base = palette(&[("ink", "#000000"), ("inkTertiary", "#000000")]);
        let shell = palette(&[("ink", "#ffffff")]);
        // Half way from the file's ink to the base's tertiary ink.
        let [r, ..] = hex(resolve(&shell, &base, false, "inkSecondary")).unwrap();
        assert!((127..=128).contains(&r), "{r}");
        // A file that sets none of it leaves the base's.
        assert_eq!(
            hex(resolve(&Palette::new(), &base, false, "inkSecondary")),
            Some([0, 0, 0, 255])
        );
    }

    #[test]
    fn a_destructive_fill_reads_white_text_at_aa() {
        let base = palette(&[("error", "#ff6b6b")]);
        let [r, g, b, a] = hex(resolve(&Palette::new(), &base, false, "destructiveFill")).unwrap();
        assert_eq!(a, 255);
        assert!(r < 0xff && g < 0x6b && b < 0x6b, "{r} {g} {b}");
    }

    #[test]
    fn the_scrim_has_a_default_per_appearance() {
        let none = Palette::new();
        assert_eq!(
            hex(resolve(&none, &none, true, "scrim")),
            Some([0x14, 0x16, 0x1a, 82])
        );
        assert_eq!(
            hex(resolve(&none, &none, false, "scrim")),
            Some([0, 0, 0, 143])
        );
        assert_eq!(resolve(&none, &none, false, "nothing"), None);
    }
}
