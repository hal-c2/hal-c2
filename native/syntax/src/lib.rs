//! Code coloured by its language, for every client that draws code: syntect
//! over bat's syntaxes (two-face), coloured as the web client's Shiki was, with
//! the Pierre light and dark themes.
//!
//! A [`Highlighter`] reads code a line at a time and keeps where it got to, so
//! a block still being written is read once, line by line, as it grows. Each
//! run of text it colours comes back once per [`Theme`]: the client keeps both
//! and switches between them without reading the code again. A run that keeps
//! the theme's own text colour is left out, so it takes the client's.
//!
//! desktop-qt and the phone call it through the C functions in [`ffi`]; a Rust
//! client uses the crate as it is.

use std::str::FromStr;
use std::sync::LazyLock;

use syntect::highlighting::{
    Color, FontStyle, HighlightState, Highlighter as ThemeHighlighter, RangedHighlightIterator,
    ScopeSelectors, StyleModifier, Theme as SyntectTheme, ThemeItem, ThemeSettings,
};
use syntect::parsing::{ParseState, ScopeStack, SyntaxReference, SyntaxSet};

pub mod ffi;

/// A line longer than this is not coloured, nor anything after it: one
/// minified line can take a regex engine seconds.
pub const MAX_LINE_BYTES: usize = 16 * 1024;

static SYNTAXES: LazyLock<SyntaxSet> = LazyLock::new(two_face::syntax::extra_newlines);

static THEMES: LazyLock<[SyntectTheme; 2]> = LazyLock::new(|| {
    [
        vscode_theme(include_str!("../themes/pierre-light.json")),
        vscode_theme(include_str!("../themes/pierre-dark.json")),
    ]
});

static THEME_HIGHLIGHTERS: LazyLock<[ThemeHighlighter<'static>; 2]> =
    LazyLock::new(|| [ThemeHighlighter::new(&THEMES[0]), ThemeHighlighter::new(&THEMES[1])]);

/// Which of the two colourings: for code on a light background or a dark one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Theme {
    Light = 0,
    Dark = 1,
}

pub const THEMES_ALL: [Theme; 2] = [Theme::Light, Theme::Dark];

/// A run of coloured text. `start` and `len` count UTF-16 units from the start
/// of everything the highlighter has read, as Qt counts a document.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Span {
    pub theme: Theme,
    pub start: u32,
    pub len: u32,
    /// `0xAARRGGBB`.
    pub color: u32,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
}

/// One block or file of code in one language, read a line at a time.
#[derive(Clone)]
pub struct Highlighter {
    parse: ParseState,
    states: [HighlightState; 2],
    /// UTF-16 units read so far.
    offset: u32,
    /// A line was too long; nothing more is coloured.
    stopped: bool,
}

impl Highlighter {
    /// A highlighter for a fence's language (`ts`, `Elixir`, `py`, …), or
    /// `None` for plain text and languages it does not know.
    pub fn for_language(language: &str) -> Option<Self> {
        syntax_for_language(language).map(Self::new)
    }

    /// A highlighter for a file by its name (`src/app.ts`, `Dockerfile`), or
    /// `None` when its kind has no syntax.
    pub fn for_path(path: &str) -> Option<Self> {
        syntax_for_path(path).map(Self::new)
    }

    fn new(syntax: &'static SyntaxReference) -> Self {
        let state = |index: usize| HighlightState::new(&THEME_HIGHLIGHTERS[index], ScopeStack::new());
        Highlighter {
            parse: ParseState::new(syntax),
            states: [state(0), state(1)],
            offset: 0,
            stopped: false,
        }
    }

    /// Whether a line was too long to colour; the rest of the code is plain.
    pub fn stopped(&self) -> bool {
        self.stopped
    }

    /// Reads `text`, whole lines continuing from where the last call left off
    /// (a last line without its `\n` is read as it is), and hands `emit` each
    /// coloured run.
    pub fn feed(&mut self, text: &str, mut emit: impl FnMut(Span)) {
        for line in text.split_inclusive('\n') {
            let units = utf16_len(line);
            if !self.stopped && line.len() > MAX_LINE_BYTES {
                self.stopped = true;
            }
            if !self.stopped && !self.feed_line(line, &mut emit) {
                self.stopped = true;
            }
            self.offset += units;
        }
    }

    fn feed_line(&mut self, line: &str, emit: &mut impl FnMut(Span)) -> bool {
        let Ok(ops) = self.parse.parse_line(line, &SYNTAXES) else {
            return false;
        };
        for theme in THEMES_ALL {
            let index = theme as usize;
            let highlighter = &THEME_HIGHLIGHTERS[index];
            let plain = THEMES[index].settings.foreground;
            let mut at = self.offset;
            for (style, piece, _) in RangedHighlightIterator::new(&mut self.states[index], &ops, line, highlighter) {
                let len = utf16_len(piece);
                let shown = piece.trim_end_matches(['\n', '\r']);
                let fonts = style.font_style;
                let coloured = Some(style.foreground) != plain || !fonts.is_empty();
                if coloured && !shown.trim().is_empty() {
                    emit(Span {
                        theme,
                        start: at,
                        len: utf16_len(shown),
                        color: argb(style.foreground),
                        bold: fonts.contains(FontStyle::BOLD),
                        italic: fonts.contains(FontStyle::ITALIC),
                        underline: fonts.contains(FontStyle::UNDERLINE),
                    });
                }
                at += len;
            }
        }
        true
    }
}

/// Every run in `text` at once, for code that is not being written.
pub fn highlight(language: &str, text: &str) -> Vec<Span> {
    let mut spans = Vec::new();
    if let Some(mut highlighter) = Highlighter::for_language(language) {
        highlighter.feed(text, |span| spans.push(span));
    }
    spans
}

/// The syntax a fence's language names: the names chat replies use, then
/// syntect's own (a syntax's name or one of its file extensions).
fn syntax_for_language(language: &str) -> Option<&'static SyntaxReference> {
    let token = language.trim().to_ascii_lowercase();
    let name = match token.as_str() {
        "" | "text" | "txt" | "plain" | "plaintext" | "mermaid" | "math" | "latex" | "tex" => return None,
        "ts" | "typescript" | "mts" | "cts" => "TypeScript",
        "tsx" => "TypeScriptReact",
        "js" | "javascript" | "mjs" | "cjs" | "node" => "JavaScript",
        "jsx" => "TypeScriptReact",
        "py" | "python" | "python3" => "Python",
        "sh" | "bash" | "shell" | "zsh" | "console" | "shellsession" => "Bourne Again Shell (bash)",
        "ex" | "exs" | "elixir" | "iex" => "Elixir",
        "heex" | "eex" | "leex" => "HTML (EEx)",
        "rs" | "rust" => "Rust",
        "qml" | "qmljs" => "QML",
        "md" | "markdown" | "mdx" => "Markdown",
        "yml" | "yaml" => "YAML",
        "json" | "jsonc" | "json5" => "JSON",
        "toml" => "TOML",
        "c++" | "cpp" | "cxx" | "hpp" | "hh" | "cc" => "C++",
        "h" | "c" => "C",
        "cs" | "csharp" | "c#" => "C#",
        "kt" | "kotlin" | "kts" => "Kotlin",
        "go" | "golang" => "Go",
        "rb" | "ruby" => "Ruby",
        "diff" | "patch" => "Diff",
        "dockerfile" | "docker" => "Dockerfile",
        "make" | "makefile" => "Makefile",
        "ps1" | "powershell" | "pwsh" => "PowerShell",
        "objc" | "objective-c" => "Objective-C",
        "html" | "htm" | "xhtml" => "HTML",
        "xml" | "svg" | "plist" => "XML",
        "gitignore" => "Git Ignore",
        "ini" | "cfg" | "conf" => "INI",
        "sql" | "psql" | "plpgsql" => "SQL",
        "swift" => "Swift",
        "zig" => "Zig",
        "nix" => "Nix",
        "lua" => "Lua",
        "java" => "Java",
        "cmake" => "CMake",
        "css" => "CSS",
        "scss" => "SCSS",
        "erl" | "erlang" => "Erlang",
        "hs" | "haskell" => "Haskell",
        "graphql" | "gql" => "GraphQL",
        _ => "",
    };
    let set = &*SYNTAXES;
    let found = if name.is_empty() { None } else { set.find_syntax_by_name(name) };
    found.or_else(|| set.find_syntax_by_token(&token)).filter(|syntax| syntax.name != "Plain Text")
}

/// The syntax for a file: its whole name (`Dockerfile`, `Makefile`), then its
/// extension, then a fence's language of that name.
fn syntax_for_path(path: &str) -> Option<&'static SyntaxReference> {
    let name = path.rsplit(['/', '\\']).next().unwrap_or(path);
    let set = &*SYNTAXES;
    let by_name = set.find_syntax_by_extension(name);
    let extension = name.rsplit_once('.').map(|(_, extension)| extension);
    by_name
        .or_else(|| extension.and_then(|extension| set.find_syntax_by_extension(extension)))
        .or_else(|| extension.and_then(syntax_for_language))
        .or_else(|| syntax_for_language(name))
        .filter(|syntax| syntax.name != "Plain Text")
}

fn utf16_len(text: &str) -> u32 {
    text.chars().map(|c| c.len_utf16() as u32).sum()
}

fn argb(color: Color) -> u32 {
    (u32::from(color.a) << 24) | (u32::from(color.r) << 16) | (u32::from(color.g) << 8) | u32::from(color.b)
}

/// A VS Code theme's `tokenColors` as a syntect theme, as Shiki reads them.
fn vscode_theme(json: &str) -> SyntectTheme {
    let value: serde_json::Value = serde_json::from_str(json).unwrap_or_default();
    let foreground = value["colors"]["editor.foreground"].as_str().and_then(parse_color);
    let mut scopes = Vec::new();
    for rule in value["tokenColors"].as_array().into_iter().flatten() {
        let settings = &rule["settings"];
        let style = StyleModifier {
            foreground: settings["foreground"].as_str().and_then(parse_color),
            background: None,
            font_style: settings["fontStyle"].as_str().map(font_style),
        };
        let selectors = match &rule["scope"] {
            serde_json::Value::String(scope) => scope.clone(),
            serde_json::Value::Array(scopes) => {
                scopes.iter().filter_map(serde_json::Value::as_str).collect::<Vec<_>>().join(", ")
            }
            _ => continue,
        };
        if let Ok(scope) = ScopeSelectors::from_str(&selectors) {
            scopes.push(ThemeItem { scope, style });
        }
    }
    SyntectTheme {
        name: value["name"].as_str().map(str::to_owned),
        author: None,
        settings: ThemeSettings { foreground, ..ThemeSettings::default() },
        scopes,
    }
}

fn font_style(text: &str) -> FontStyle {
    text.split_whitespace().fold(FontStyle::empty(), |style, word| match word {
        "bold" => style | FontStyle::BOLD,
        "italic" => style | FontStyle::ITALIC,
        "underline" => style | FontStyle::UNDERLINE,
        _ => style,
    })
}

fn parse_color(text: &str) -> Option<Color> {
    let hex = text.strip_prefix('#')?;
    let byte = |at: usize| u8::from_str_radix(hex.get(at..at + 2)?, 16).ok();
    match hex.len() {
        6 => Some(Color { r: byte(0)?, g: byte(2)?, b: byte(4)?, a: 0xff }),
        8 => Some(Color { r: byte(0)?, g: byte(2)?, b: byte(4)?, a: byte(6)? }),
        _ => None,
    }
}

#[cfg(test)]
mod tests;
