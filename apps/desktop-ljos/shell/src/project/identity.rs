//! How a project is told apart at a glance, desktop-qt's `projectidentity`:
//! the icon the user picked, else a two-character monogram in a colour, both
//! derived from its name.

use serde_json::json;
use unicode_general_category::{GeneralCategory as Category, get_general_category};
use unicode_normalization::UnicodeNormalization;

use crate::json::Json;

/// The automatic monogram and colour of a project.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Identity {
    pub monogram: String,
    pub color: String,
}

/// packages/contracts ProjectIconColor, in the picker's order.
pub const COLORS: [&str; 18] = [
    "gray", "red", "orange", "amber", "yellow", "lime", "green", "emerald", "teal", "cyan", "sky",
    "blue", "indigo", "violet", "purple", "fuchsia", "pink", "rose",
];

/// The lucide icons the picker offers (those js/lucide.js can draw).
pub const SYMBOLS: [&str; 30] = [
    "folder-code",
    "rocket",
    "package",
    "database",
    "shopping-cart",
    "book",
    "bug",
    "cpu",
    "flask-conical",
    "gamepad-2",
    "music",
    "palette",
    "shield",
    "heart",
    "globe",
    "terminal",
    "code",
    "zap",
    "star",
    "bot",
    "brain",
    "sparkles",
    "lightbulb",
    "server",
    "cloud",
    "laptop",
    "smartphone",
    "wrench",
    "hammer",
    "image",
];

const GRAY: &str = "#6b7280";

/// The colour as the bricks paint it (Tailwind's 500s); gray for one this
/// build does not know.
pub fn tint(color: &str) -> &'static str {
    match color {
        "red" => "#ef4444",
        "orange" => "#f97316",
        "amber" => "#f59e0b",
        "yellow" => "#eab308",
        "lime" => "#84cc16",
        "green" => "#22c55e",
        "emerald" => "#10b981",
        "teal" => "#14b8a6",
        "cyan" => "#06b6d4",
        "sky" => "#0ea5e9",
        "blue" => "#3b82f6",
        "indigo" => "#6366f1",
        "violet" => "#8b5cf6",
        "purple" => "#a855f7",
        "fuchsia" => "#d946ef",
        "pink" => "#ec4899",
        "rose" => "#f43f5e",
        _ => GRAY,
    }
}

fn is_letter(c: char) -> bool {
    use Category::*;
    matches!(
        get_general_category(c),
        UppercaseLetter | LowercaseLetter | TitlecaseLetter | ModifierLetter | OtherLetter
    )
}

fn is_number(c: char) -> bool {
    use Category::*;
    matches!(
        get_general_category(c),
        DecimalNumber | LetterNumber | OtherNumber
    )
}

fn is_mark(c: char) -> bool {
    use Category::*;
    matches!(
        get_general_category(c),
        NonspacingMark | SpacingMark | EnclosingMark
    )
}

fn normalized(name: &str) -> String {
    name.nfkc().collect::<String>().trim().to_owned()
}

/// Upper case a character at a time, as Qt does: no context, so the same
/// text gives the same letters wherever it sits.
fn upper(text: &str) -> String {
    text.chars().flat_map(char::to_uppercase).collect()
}

fn lower(text: &str) -> String {
    text.chars().flat_map(char::to_lowercase).collect()
}

/// The automatic monogram and colour of a project called `name`.
pub fn derive(name: &str) -> Identity {
    let clean = normalized(name);
    let words: Vec<&str> = clean
        .split(|c: char| !(is_letter(c) || is_number(c)))
        .filter(|w| !w.is_empty())
        .collect();
    let mut letters = String::from("PR");
    if let (Some(first_word), Some(last_word)) = (words.first(), words.last()) {
        let first: Vec<char> = first_word.chars().collect();
        // The first number after the first character, else the last word's
        // first character (the first word's last when it is alone).
        let second = first
            .iter()
            .skip(1)
            .copied()
            .find(|c| is_number(*c))
            .or_else(|| {
                if words.len() > 1 {
                    last_word.chars().next()
                } else {
                    first.last().copied()
                }
            });
        if let (Some(head), Some(second)) = (first.first(), second) {
            letters = upper(&format!("{head}{second}")).chars().take(2).collect();
        }
    }
    let seed = lower(&clean);
    let seed = if seed.is_empty() { "project" } else { &seed };
    let index = seed.chars().fold(0usize, |index, glyph| {
        (index * 31 + glyph as usize) % COLORS.len()
    });
    Identity {
        monogram: letters,
        color: COLORS[index].to_owned(),
    }
}

/// What the user typed as a monogram, as it is saved: NFKC, trimmed, upper
/// case.
pub fn monogram(typed: &str) -> String {
    upper(&normalized(typed))
}

/// One or two letters or numbers (ProjectMonogramText, counted in characters
/// as the server counts them).
pub fn valid_monogram(text: &str) -> bool {
    let mut chars = text.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if !(is_letter(first) || is_number(first)) {
        return false;
    }
    let rides = |c: char| is_mark(c) || c == '\u{200c}' || c == '\u{200d}';
    if !chars
        .clone()
        .all(|c| is_letter(c) || is_number(c) || rides(c))
    {
        return false;
    }
    // Marks and joiners ride on the character before them.
    let characters = text.chars().filter(|c| !rides(*c)).count();
    (1..=2).contains(&characters)
}

fn text<'a>(object: &'a Json, key: &str) -> &'a str {
    object.get(key).and_then(Json::as_str).unwrap_or_default()
}

/// A project row's icon for the bricks: `{kind (monogram | emoji | lucide),
/// text, emoji, name, color, tint, automatic}`. A monogram an older server
/// keeps as a folder symbol with letters reads as a monogram.
pub fn icon(row: &Json) -> Json {
    let empty = json!({});
    let picked = row
        .get("projectIcon")
        .filter(|v| v.is_object())
        .unwrap_or(&empty);
    let kind = text(picked, "kind");
    let mut letters = if kind == "monogram" {
        text(picked, "text")
    } else {
        text(picked, "monogramText")
    };
    if letters.is_empty() && kind == "lucide" {
        letters = text(picked, "monogram");
    }
    let color = text(picked, "color");
    if kind == "emoji" {
        return json!({"kind": kind, "emoji": text(picked, "emoji"), "automatic": false});
    }
    if !letters.is_empty() {
        return json!({
            "kind": "monogram", "text": letters, "color": color,
            "tint": tint(color), "automatic": false,
        });
    }
    if kind == "lucide" {
        // A symbol this build cannot draw shows as the folder.
        let symbol = text(picked, "name");
        let name = if SYMBOLS.contains(&symbol) {
            symbol
        } else {
            "folder-code"
        };
        return json!({
            "kind": kind, "name": name, "symbol": symbol, "color": color,
            "tint": tint(color), "automatic": false,
        });
    }
    let automatic = derive(text(row, "title"));
    json!({
        "kind": "monogram", "text": automatic.monogram, "color": automatic.color,
        "tint": tint(&automatic.color), "automatic": true,
    })
}

/// The picked icon as the MC keeps it: a monogram travels as a folder symbol
/// carrying its letters, so servers that only know symbols still show it.
pub fn wire(kind: &str, value: &str, color: &str) -> Json {
    match kind {
        "emoji" => json!({"kind": kind, "emoji": value}),
        "monogram" => json!({
            "kind": "lucide", "name": "folder-code", "color": color, "monogramText": value,
        }),
        _ => json!({"kind": "lucide", "name": value, "color": color}),
    }
}

/// Whether a file can be a project's icon, by its extension.
pub fn is_image(path: &str) -> bool {
    const EXTENSIONS: [&str; 9] = [
        "png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "avif", "bmp",
    ];
    path.rsplit_once('.')
        .is_some_and(|(_, extension)| EXTENSIONS.contains(&lower(extension).as_str()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn automatic(name: &str) -> String {
        derive(name).monogram
    }

    // features/files/project-identity.feature: "A project without an icon
    // shows a two-character monogram".
    #[test]
    fn a_name_gives_two_characters() {
        assert_eq!(automatic("Nebula"), "NA");
        assert_eq!(automatic("Silver Orchard"), "SO");
        assert_eq!(automatic("M7 Forge"), "M7");
        assert_eq!(automatic("a"), "AA");
        assert_eq!(automatic("hal-c2"), "HC");
    }

    #[test]
    fn a_name_without_letters_or_numbers_is_pr() {
        assert_eq!(automatic(""), "PR");
        assert_eq!(automatic(" -- "), "PR");
    }

    #[test]
    fn characters_are_code_points_not_utf16_units() {
        // A glyph outside the basic plane is one character.
        assert_eq!(automatic("\u{10428}\u{10429}"), "\u{10400}\u{10401}");
    }

    #[test]
    fn the_colour_follows_the_name_alone() {
        let a = derive("Nebula");
        assert_eq!(a, derive("  nebula "));
        assert!(COLORS.contains(&a.color.as_str()));
        // Fixed by the algorithm: ("project" folded by 31, mod 18).
        let seed = "project"
            .chars()
            .fold(0usize, |i, c| (i * 31 + c as usize) % 18);
        assert_eq!(derive("").color, COLORS[seed]);
    }

    #[test]
    fn a_colour_this_build_does_not_know_is_gray() {
        assert_eq!(tint("rose"), "#f43f5e");
        assert_eq!(tint("chartreuse"), GRAY);
        assert_eq!(tint(""), GRAY);
        assert!(COLORS.iter().all(|c| tint(c).starts_with('#')));
    }

    #[test]
    fn a_typed_monogram_is_tidied() {
        assert_eq!(monogram("sh"), "SH");
        assert_eq!(monogram(" ｓｈ "), "SH");
    }

    // "Monograms take one or two letters or numbers".
    #[test]
    fn a_monogram_is_one_or_two_letters_or_numbers() {
        assert!(valid_monogram("SH"));
        assert!(valid_monogram("7"));
        assert!(valid_monogram("M7"));
        assert!(!valid_monogram("ABC"));
        assert!(!valid_monogram("#!"));
        assert!(!valid_monogram(""));
        assert!(!valid_monogram("A B"));
    }

    #[test]
    fn marks_and_joiners_ride_on_the_character_before_them() {
        assert!(valid_monogram("e\u{301}x"));
        assert!(valid_monogram("a\u{200d}b"));
        assert!(!valid_monogram("\u{301}a"));
        assert!(!valid_monogram("e\u{301}xy"));
    }

    #[test]
    fn a_project_without_an_icon_shows_its_automatic_one() {
        let icon = icon(&json!({"title": "Nebula"}));
        assert_eq!(icon["kind"], "monogram");
        assert_eq!(icon["text"], "NA");
        assert_eq!(icon["automatic"], true);
        assert_eq!(icon["tint"], tint(icon["color"].as_str().unwrap()));
    }

    #[test]
    fn a_picked_emoji_shows_as_it_is() {
        let icon = icon(&json!({"projectIcon": {"kind": "emoji", "emoji": "🛒"}}));
        assert_eq!(
            icon,
            json!({"kind": "emoji", "emoji": "🛒", "automatic": false})
        );
    }

    #[test]
    fn a_monogram_an_older_server_keeps_as_a_symbol_reads_as_a_monogram() {
        let kept = wire("monogram", "SH", "rose");
        let icon = icon(&json!({"projectIcon": kept}));
        assert_eq!(icon["kind"], "monogram");
        assert_eq!(icon["text"], "SH");
        assert_eq!(icon["tint"], "#f43f5e");
        assert_eq!(icon["automatic"], false);
        // Servers that know monograms send the letters as `text`.
        let icon = super::icon(
            &json!({"projectIcon": {"kind": "monogram", "text": "AB", "color": "blue"}}),
        );
        assert_eq!(
            (&icon["text"], &icon["tint"]),
            (&json!("AB"), &json!("#3b82f6"))
        );
    }

    #[test]
    fn a_symbol_this_build_cannot_draw_shows_as_the_folder() {
        let icon =
            icon(&json!({"projectIcon": {"kind": "lucide", "name": "rocket", "color": "teal"}}));
        assert_eq!(
            (&icon["name"], &icon["symbol"]),
            (&json!("rocket"), &json!("rocket"))
        );
        let icon =
            super::icon(&json!({"projectIcon": {"kind": "lucide", "name": "hot-air-balloon"}}));
        assert_eq!(
            (&icon["name"], &icon["symbol"], &icon["tint"]),
            (
                &json!("folder-code"),
                &json!("hot-air-balloon"),
                &json!(GRAY)
            )
        );
    }

    #[test]
    fn the_wire_form_of_each_kind() {
        assert_eq!(
            wire("emoji", "🛒", "rose"),
            json!({"kind": "emoji", "emoji": "🛒"})
        );
        assert_eq!(
            wire("symbol", "rocket", "teal"),
            json!({"kind": "lucide", "name": "rocket", "color": "teal"})
        );
        assert_eq!(
            wire("monogram", "SH", "rose"),
            json!({"kind": "lucide", "name": "folder-code", "color": "rose", "monogramText": "SH"})
        );
    }

    #[test]
    fn an_image_is_told_by_its_extension() {
        assert!(is_image("assets/logo.PNG"));
        assert!(is_image("a.b/c.webp"));
        assert!(!is_image("README.md"));
        assert!(!is_image("png"));
    }
}
