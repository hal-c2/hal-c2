//! The keymap, desktop-qt's Keybindings.cpp: the defaults, the user's rules
//! from the MC's keybindings.json merged over them, `when` conditions, and
//! the last matching rule winning. Plain values; the `Keybindings` singleton
//! (controllers/keybindings.rs) runs them.

use std::collections::{HashMap, HashSet};
use std::sync::LazyLock;

use serde_json::json;

use crate::json::Json;

/// packages/contracts MAX_KEYBINDINGS_COUNT and MAX_WHEN_EXPRESSION_DEPTH.
const MAX_BINDINGS: usize = 256;
const MAX_WHEN_DEPTH: usize = 64;

/// A parsed key: "mod+shift+[" is {key "[", shift, mod}. `mod` is Command on
/// macOS and Ctrl elsewhere.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Shortcut {
    pub key: String,
    pub meta: bool,
    pub ctrl: bool,
    pub shift: bool,
    pub alt: bool,
    pub mod_: bool,
}

/// A `when` condition: identifiers joined by !, && and ||.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum When {
    Identifier(String),
    Not(Box<When>),
    And(Box<When>, Box<When>),
    Or(Box<When>, Box<When>),
}

impl When {
    /// Every identifier it names, in order.
    pub fn identifiers<'a>(&'a self, out: &mut Vec<&'a str>) {
        match self {
            When::Identifier(name) => out.push(name),
            When::Not(inner) => inner.identifiers(out),
            When::And(l, r) | When::Or(l, r) => {
                l.identifiers(out);
                r.identifiers(out);
            }
        }
    }
}

/// One rule as keybindings.json holds it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Rule {
    pub key: String,
    pub command: String,
    pub when: Option<String>,
}

impl Rule {
    pub fn new(key: &str, command: &str, when: &str) -> Rule {
        Rule {
            key: key.to_owned(),
            command: command.to_owned(),
            when: (!when.is_empty()).then(|| when.to_owned()),
        }
    }

    /// `{key, command, when?}`; a `when` that is null is none.
    pub fn from_json(value: &Json) -> Option<Rule> {
        let key = value.get("key")?.as_str()?;
        let command = value.get("command")?.as_str()?;
        let when = match value.get("when") {
            None | Some(Json::Null) => None,
            Some(Json::String(when)) => Some(when.clone()),
            Some(_) => return None,
        };
        Some(Rule {
            key: key.to_owned(),
            command: command.to_owned(),
            when,
        })
    }

    pub fn to_json(&self) -> Json {
        let mut object = json!({"key": self.key, "command": self.command});
        if let Some(when) = &self.when {
            object["when"] = json!(when);
        }
        object
    }
}

/// A rule that parsed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Binding {
    pub command: String,
    pub shortcut: Shortcut,
    /// None: always.
    pub when: Option<When>,
    /// As written, which the MC matches a remove or replace by.
    pub rule: Rule,
}

/// The identifiers a condition is evaluated against; unknown ones are false.
pub type Context = HashMap<String, bool>;

pub fn parse_shortcut(value: &str) -> Option<Shortcut> {
    let lower = value.to_lowercase();
    let mut tokens: Vec<&str> = lower.split('+').map(str::trim).collect();
    let mut trailing = false;
    while tokens.last().is_some_and(|t| t.is_empty()) {
        tokens.pop();
        trailing = true;
    }
    if trailing {
        tokens.push("+");
    }
    if tokens.is_empty() || tokens.contains(&"") {
        return None;
    }
    let mut shortcut = Shortcut::default();
    let mut have_key = false;
    for token in tokens {
        match token {
            "cmd" | "meta" => shortcut.meta = true,
            "ctrl" | "control" => shortcut.ctrl = true,
            "shift" => shortcut.shift = true,
            "alt" | "option" => shortcut.alt = true,
            "mod" => shortcut.mod_ = true,
            _ => {
                if have_key {
                    return None;
                }
                have_key = true;
                shortcut.key = match token {
                    "space" => " ".to_owned(),
                    "esc" => "escape".to_owned(),
                    other => other.to_owned(),
                };
            }
        }
    }
    have_key.then_some(shortcut)
}

#[derive(Clone, Debug, PartialEq)]
enum Token {
    Identifier(String),
    Not,
    And,
    Or,
    Open,
    Close,
}

/// The `when` grammar: or := and ("||" and)*, and := unary ("&&" unary)*,
/// unary := "!"* primary, primary := identifier | "(" or ")".
struct WhenParser {
    tokens: Vec<Token>,
    index: usize,
}

impl WhenParser {
    fn tokenize(expression: &str) -> Option<Vec<Token>> {
        let chars: Vec<char> = expression.chars().collect();
        let mut tokens = Vec::new();
        let mut i = 0;
        while i < chars.len() {
            let c = chars[i];
            let next = chars.get(i + 1).copied();
            if c.is_whitespace() {
                i += 1;
            } else if c == '&' && next == Some('&') {
                tokens.push(Token::And);
                i += 2;
            } else if c == '|' && next == Some('|') {
                tokens.push(Token::Or);
                i += 2;
            } else if c == '!' {
                tokens.push(Token::Not);
                i += 1;
            } else if c == '(' {
                tokens.push(Token::Open);
                i += 1;
            } else if c == ')' {
                tokens.push(Token::Close);
                i += 1;
            } else if c.is_ascii_alphabetic() || c == '_' {
                // [A-Za-z_][A-Za-z0-9_.-]*
                let start = i;
                i += 1;
                while i < chars.len()
                    && (chars[i].is_ascii_alphanumeric() || matches!(chars[i], '_' | '.' | '-'))
                {
                    i += 1;
                }
                tokens.push(Token::Identifier(chars[start..i].iter().collect()));
            } else {
                return None;
            }
        }
        Some(tokens)
    }

    fn at(&self, token: &Token) -> bool {
        self.tokens
            .get(self.index)
            .is_some_and(|t| std::mem::discriminant(t) == std::mem::discriminant(token))
    }

    fn primary(&mut self, depth: usize) -> Option<When> {
        if depth > MAX_WHEN_DEPTH {
            return None;
        }
        match self.tokens.get(self.index)? {
            Token::Identifier(name) => {
                let name = name.clone();
                self.index += 1;
                Some(When::Identifier(name))
            }
            Token::Open => {
                self.index += 1;
                let inner = self.or(depth + 1)?;
                if !self.at(&Token::Close) {
                    return None;
                }
                self.index += 1;
                Some(inner)
            }
            _ => None,
        }
    }

    fn unary(&mut self, depth: usize) -> Option<When> {
        let mut nots = 0;
        while self.at(&Token::Not) {
            self.index += 1;
            nots += 1;
            if nots > MAX_WHEN_DEPTH {
                return None;
            }
        }
        let mut node = self.primary(depth)?;
        for _ in 0..nots {
            node = When::Not(Box::new(node));
        }
        Some(node)
    }

    fn and(&mut self, depth: usize) -> Option<When> {
        let mut left = self.unary(depth)?;
        while self.at(&Token::And) {
            self.index += 1;
            let right = self.unary(depth)?;
            left = When::And(Box::new(left), Box::new(right));
        }
        Some(left)
    }

    fn or(&mut self, depth: usize) -> Option<When> {
        let mut left = self.and(depth)?;
        while self.at(&Token::Or) {
            self.index += 1;
            let right = self.and(depth)?;
            left = When::Or(Box::new(left), Box::new(right));
        }
        Some(left)
    }
}

/// None when the condition is malformed or nested too deep.
pub fn parse_when(expression: &str) -> Option<When> {
    let tokens = WhenParser::tokenize(expression)?;
    if tokens.is_empty() {
        return None;
    }
    let mut parser = WhenParser { tokens, index: 0 };
    let ast = parser.or(0)?;
    (parser.index == parser.tokens.len()).then_some(ast)
}

pub fn evaluate(when: Option<&When>, context: &Context) -> bool {
    let Some(when) = when else { return true };
    match when {
        When::Identifier(name) => match name.as_str() {
            "true" => true,
            "false" => false,
            _ => context.get(name).copied().unwrap_or(false),
        },
        When::Not(inner) => !evaluate(Some(inner), context),
        When::And(l, r) => evaluate(Some(l), context) && evaluate(Some(r), context),
        When::Or(l, r) => evaluate(Some(l), context) || evaluate(Some(r), context),
    }
}

pub fn compile(rule: &Rule) -> Option<Binding> {
    let shortcut = parse_shortcut(&rule.key)?;
    let when = match &rule.when {
        Some(when) => Some(parse_when(when)?),
        None => None,
    };
    Some(Binding {
        command: rule.command.clone(),
        shortcut,
        when,
        rule: rule.clone(),
    })
}

static COMMANDS: LazyLock<Vec<String>> = LazyLock::new(|| {
    let mut list: Vec<String> = [
        "sidebar.toggle",
        "navigation.back",
        "navigation.forward",
        "tabs.next",
        "tabs.previous",
        "terminal.toggle",
        "terminal.split",
        "terminal.splitVertical",
        "terminal.new",
        "terminal.close",
        "rightPanel.toggle",
        "threadPanel.toggle",
        "rightPanel.toggleMaximized",
        "rightPanel.close",
        "pullRequest.copyNumber",
        "diff.toggle",
        "preview.toggle",
        "preview.refresh",
        "preview.focusUrl",
        "preview.zoomIn",
        "preview.zoomOut",
        "preview.resetZoom",
        "commandPalette.toggle",
        "filePicker.toggle",
        "projectSearch.toggle",
        "theme.select",
        "appearance.cycle",
        "themeEditor.toggle",
        "composer.stash",
        "composer.sendAlternate",
        "composer.sendBackground",
        "composer.host",
        "composer.effort",
        "composer.mode",
        "composer.workspace",
        "composer.previousWorktree",
        "composer.branch",
        "chat.new",
        "chat.newLocal",
        "editor.openFavorite",
        "modelPicker.toggle",
        "modelPicker.previousProvider",
        "modelPicker.nextProvider",
    ]
    .map(str::to_owned)
    .to_vec();
    list.extend((1..=9).map(|n| format!("modelPicker.jump.{n}")));
    list.extend(
        [
            "thread.stop",
            "thread.steerQueuedMessage",
            "thread.editQueuedMessage",
            "thread.previous",
            "thread.next",
            "thread.copyReference",
            "thread.settle",
            "thread.pin",
            "thread.undo",
        ]
        .map(str::to_owned),
    );
    list.extend((1..=9).map(|n| format!("thread.jump.{n}")));
    list
});

/// STATIC_KEYBINDING_COMMANDS; `script.<id>.run` is a command too.
pub fn commands() -> &'static [String] {
    &COMMANDS
}

/// `script.<id>.run`'s id, when `command` is one; any id, as the shell runs
/// it.
pub fn script_id(command: &str) -> Option<&str> {
    command.strip_prefix("script.")?.strip_suffix(".run")
}

pub fn is_command(command: &str) -> bool {
    static KNOWN: LazyLock<HashSet<&'static str>> =
        LazyLock::new(|| COMMANDS.iter().map(String::as_str).collect());
    if KNOWN.contains(command) {
        return true;
    }
    // SCRIPT_RUN_COMMAND_PATTERN, with MAX_SCRIPT_ID_LENGTH:
    // ^script\.[a-z0-9][a-z0-9-]{0,23}\.run$
    let Some(id) = script_id(command) else {
        return false;
    };
    let mut chars = id.chars();
    chars
        .next()
        .is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        && id.len() <= 24
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

static DEFAULTS: LazyLock<Vec<Rule>> = LazyLock::new(|| {
    let not_terminal = "!terminalFocus";
    let terminal = "terminalFocus";
    let preview = "previewFocus";
    let mut rules: Vec<Rule> = [
        ("mod+b", "sidebar.toggle", ""),
        ("mod+[", "navigation.back", not_terminal),
        ("mod+]", "navigation.forward", not_terminal),
        ("mod+alt+]", "tabs.next", not_terminal),
        ("mod+alt+[", "tabs.previous", not_terminal),
        ("mod+j", "terminal.toggle", ""),
        ("mod+alt+b", "rightPanel.toggle", ""),
        ("mod+d", "terminal.split", terminal),
        ("mod+shift+d", "terminal.splitVertical", terminal),
        ("mod+n", "terminal.new", terminal),
        ("mod+w", "terminal.close", terminal),
        ("mod+w", "rightPanel.close", not_terminal),
        ("mod+d", "diff.toggle", not_terminal),
        ("mod+shift+j", "preview.toggle", ""),
        ("mod+r", "preview.refresh", preview),
        ("mod+l", "preview.focusUrl", preview),
        ("mod+=", "preview.zoomIn", preview),
        ("mod++", "preview.zoomIn", preview),
        ("mod+-", "preview.zoomOut", preview),
        ("mod+0", "preview.resetZoom", preview),
        ("mod+k", "commandPalette.toggle", not_terminal),
        ("mod+p", "filePicker.toggle", not_terminal),
        ("mod+shift+f", "projectSearch.toggle", not_terminal),
        ("mod+alt+a", "theme.select", not_terminal),
        ("mod+alt+shift+a", "appearance.cycle", not_terminal),
        ("mod+alt+shift+t", "themeEditor.toggle", ""),
        ("mod+s", "composer.stash", not_terminal),
        ("mod+shift+enter", "thread.steerQueuedMessage", not_terminal),
        ("alt+arrowup", "thread.editQueuedMessage", "composerFocus"),
        (
            "mod+enter",
            "composer.sendAlternate",
            "composerFocus && turnRunning",
        ),
        (
            "mod+alt+enter",
            "composer.sendBackground",
            "composerFocus && draftThreadRoute",
        ),
        ("mod+n", "chat.new", not_terminal),
        ("mod+shift+o", "chat.new", not_terminal),
        ("mod+shift+n", "chat.newLocal", not_terminal),
        ("mod+shift+m", "modelPicker.toggle", not_terminal),
        ("mod+shift+h", "composer.host", not_terminal),
        ("mod+shift+e", "composer.effort", not_terminal),
        ("mod+shift+a", "composer.mode", not_terminal),
        ("mod+shift+x", "composer.workspace", not_terminal),
        ("mod+shift+g", "composer.branch", not_terminal),
        ("mod+shift+l", "composer.previousWorktree", not_terminal),
        ("mod+shift+k", "pullRequest.copyNumber", not_terminal),
        (
            "mod+shift+arrowup",
            "modelPicker.previousProvider",
            "modelPickerOpen",
        ),
        (
            "mod+shift+arrowdown",
            "modelPicker.nextProvider",
            "modelPickerOpen",
        ),
        ("mod+o", "editor.openFavorite", ""),
        ("mod+shift+[", "thread.previous", ""),
        ("mod+shift+]", "thread.next", ""),
        ("mod+shift+c", "thread.copyReference", not_terminal),
        ("mod+shift+s", "thread.settle", not_terminal),
        ("mod+shift+p", "thread.pin", not_terminal),
        ("mod+z", "thread.undo", "!terminalFocus && !editableFocus"),
    ]
    .iter()
    .map(|(key, command, when)| Rule::new(key, command, when))
    .collect();
    for n in 1..=9 {
        rules.push(Rule::new(
            &format!("mod+{n}"),
            &format!("thread.jump.{n}"),
            "isDesktop",
        ));
    }
    for n in 1..=9 {
        rules.push(Rule::new(
            &format!("mod+{n}"),
            &format!("modelPicker.jump.{n}"),
            "modelPickerOpen && isDesktop",
        ));
    }
    rules
});

static DEFAULT_BINDINGS: LazyLock<Vec<Binding>> = LazyLock::new(|| compile_all(&DEFAULTS));

/// The default keymap, in its order.
pub fn defaults() -> &'static [Rule] {
    &DEFAULTS
}

pub fn default_bindings() -> &'static [Binding] {
    &DEFAULT_BINDINGS
}

fn compile_all(rules: &[Rule]) -> Vec<Binding> {
    let mut bindings: Vec<Binding> = rules.iter().filter_map(compile).collect();
    if bindings.len() > MAX_BINDINGS {
        bindings.drain(..bindings.len() - MAX_BINDINGS);
    }
    bindings
}

/// The user's rules over the defaults: a command the user binds loses all
/// its default bindings; rules that do not parse or name no command are
/// dropped.
pub fn merge(user_rules: &[Json]) -> Vec<Binding> {
    let rules: Vec<Rule> = user_rules
        .iter()
        .filter_map(Rule::from_json)
        .filter(|r| is_command(&r.command))
        .collect();
    let custom = compile_all(&rules);
    if custom.is_empty() {
        return default_bindings().to_vec();
    }
    let overridden: HashSet<&str> = custom.iter().map(|b| b.command.as_str()).collect();
    let mut merged: Vec<Binding> = default_bindings()
        .iter()
        .filter(|b| !overridden.contains(b.command.as_str()))
        .cloned()
        .collect();
    merged.extend(custom);
    if merged.len() > MAX_BINDINGS {
        merged.drain(..merged.len() - MAX_BINDINGS);
    }
    merged
}

/// The command the last binding for `sequence` whose condition holds runs,
/// or empty.
pub fn resolve(bindings: &[Binding], key_sequence: &str, context: &Context, mac: bool) -> String {
    bindings
        .iter()
        .rev()
        .find(|b| evaluate(b.when.as_ref(), context) && sequence(&b.shortcut, mac) == key_sequence)
        .map(|b| b.command.clone())
        .unwrap_or_default()
}

/// Browser `event.key` names -> portable QKeySequence names.
fn qt_key_name(key: &str) -> String {
    let named = match key {
        " " => "Space",
        "arrowdown" => "Down",
        "arrowleft" => "Left",
        "arrowright" => "Right",
        "arrowup" => "Up",
        "backspace" => "Backspace",
        "delete" => "Del",
        "end" => "End",
        "enter" => "Return",
        "escape" => "Esc",
        "home" => "Home",
        "insert" => "Ins",
        "pagedown" => "PgDown",
        "pageup" => "PgUp",
        "tab" => "Tab",
        _ => "",
    };
    if !named.is_empty() {
        return named.to_owned();
    }
    // ^f([1-9]|1\d|2[0-4])$
    let function = key
        .strip_prefix('f')
        .filter(|n| !n.starts_with('0'))
        .and_then(|n| n.parse::<u32>().ok())
        .is_some_and(|n| (1..=24).contains(&n));
    if function || key.chars().count() == 1 {
        return key.to_uppercase();
    }
    String::new()
}

/// The portable QKeySequence text the window registers for a shortcut, or
/// empty when the window must leave the key alone: unmodified keys belong to
/// the focused control, and a key Qt has no name for cannot be registered.
pub fn sequence(shortcut: &Shortcut, mac: bool) -> String {
    let meta = shortcut.meta || (shortcut.mod_ && mac);
    let ctrl = shortcut.ctrl || (shortcut.mod_ && !mac);
    if !meta && !ctrl && !shortcut.alt {
        return String::new();
    }
    let key = qt_key_name(&shortcut.key);
    if key.is_empty() {
        return String::new();
    }
    // Qt's portable names are swapped on macOS: "Ctrl" is Command, "Meta"
    // is Control.
    let mut parts = Vec::new();
    if if mac { meta } else { ctrl } {
        parts.push("Ctrl");
    }
    if if mac { ctrl } else { meta } {
        parts.push("Meta");
    }
    if shortcut.alt {
        parts.push("Alt");
    }
    if shortcut.shift {
        parts.push("Shift");
    }
    parts.push(&key);
    parts.join("+")
}

fn upper_first(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

/// "Ctrl+Shift+E", or "⇧⌘E" on macOS.
pub fn label(shortcut: &Shortcut, mac: bool) -> String {
    let k = shortcut.key.as_str();
    let key = if k == " " {
        "Space".to_owned()
    } else if k.chars().count() == 1 {
        k.to_uppercase()
    } else if k == "escape" {
        "Esc".to_owned()
    } else if let Some(rest) = k.strip_prefix("arrow") {
        title_case(rest)
    } else {
        upper_first(k)
    };
    let meta = shortcut.meta || (shortcut.mod_ && mac);
    let ctrl = shortcut.ctrl || (shortcut.mod_ && !mac);
    if mac {
        let mut out = String::new();
        if ctrl {
            out.push('⌃');
        }
        if shortcut.alt {
            out.push('⌥');
        }
        if shortcut.shift {
            out.push('⇧');
        }
        if meta {
            out.push('⌘');
        }
        return out + &key;
    }
    let mut parts = Vec::new();
    if ctrl {
        parts.push("Ctrl");
    }
    if shortcut.alt {
        parts.push("Alt");
    }
    if shortcut.shift {
        parts.push("Shift");
    }
    if meta {
        parts.push("Meta");
    }
    parts.push(&key);
    parts.join("+")
}

/// The key as keybindings.json spells it: "mod+shift+e".
pub fn key_text(shortcut: &Shortcut) -> String {
    let mut parts = Vec::new();
    if shortcut.mod_ {
        parts.push("mod");
    }
    if shortcut.meta {
        parts.push("meta");
    }
    if shortcut.ctrl {
        parts.push("ctrl");
    }
    if shortcut.alt {
        parts.push("alt");
    }
    if shortcut.shift {
        parts.push("shift");
    }
    parts.push(match shortcut.key.as_str() {
        " " => "space",
        "escape" => "esc",
        key => key,
    });
    parts.join("+")
}

fn wrapped(when: &When) -> String {
    match when {
        When::Identifier(_) | When::Not(_) => when_text(Some(when)),
        _ => format!("({})", when_text(Some(when))),
    }
}

/// The condition as keybindings.json spells it; empty for none.
pub fn when_text(when: Option<&When>) -> String {
    match when {
        None => String::new(),
        Some(When::Identifier(name)) => name.clone(),
        Some(When::Not(inner)) => format!("!{}", wrapped(inner)),
        Some(When::And(l, r)) => format!("{} && {}", wrapped(l), wrapped(r)),
        Some(When::Or(l, r)) => format!("{} || {}", wrapped(l), wrapped(r)),
    }
}

/// "fooBar-baz" -> "Foo Bar Baz": a space between a lower-case letter or
/// digit and a capital, words split at `-`, `_` and white space, each
/// capitalised.
fn title_case(segment: &str) -> String {
    let mut spaced = String::with_capacity(segment.len() + 4);
    let mut previous: Option<char> = None;
    for c in segment.chars() {
        if c.is_ascii_uppercase()
            && previous.is_some_and(|p| p.is_ascii_lowercase() || p.is_ascii_digit())
        {
            spaced.push(' ');
        }
        spaced.push(c);
        previous = Some(c);
    }
    spaced
        .split(|c: char| c == '-' || c == '_' || c.is_whitespace())
        .filter(|w| !w.is_empty())
        .map(upper_first)
        .collect::<Vec<_>>()
        .join(" ")
}

/// "Composer: Start in Background", "Run Script: Test", "Terminal: Toggle".
pub fn command_label(command: &str) -> String {
    let special = match command {
        "composer.sendAlternate" => "Composer: Opposite Queue or Steer Action",
        "composer.sendBackground" => "Composer: Start in Background",
        "thread.steerQueuedMessage" => "Queue: Send First Queued Message as Steer",
        "thread.editQueuedMessage" => "Queue: Edit Last Queued Message",
        "thread.copyReference" => "Pull Request: Copy Link or Thread ID",
        _ => "",
    };
    if !special.is_empty() {
        return special.to_owned();
    }
    if let Some(id) = script_id(command) {
        return format!("Run Script: {}", title_case(id));
    }
    command
        .split('.')
        .map(title_case)
        .collect::<Vec<_>>()
        .join(": ")
}

/// Qt::Key and Qt::KeyboardModifier values, as QML's key events carry them.
pub mod qt {
    pub const KEY_SPACE: i32 = 0x20;
    pub const KEY_ASCII_TILDE: i32 = 0x7e;
    pub const KEY_ESCAPE: i32 = 0x0100_0000;
    pub const KEY_TAB: i32 = 0x0100_0001;
    pub const KEY_BACKTAB: i32 = 0x0100_0002;
    pub const KEY_BACKSPACE: i32 = 0x0100_0003;
    pub const KEY_RETURN: i32 = 0x0100_0004;
    pub const KEY_ENTER: i32 = 0x0100_0005;
    pub const KEY_DELETE: i32 = 0x0100_0007;
    pub const KEY_HOME: i32 = 0x0100_0010;
    pub const KEY_END: i32 = 0x0100_0011;
    pub const KEY_LEFT: i32 = 0x0100_0012;
    pub const KEY_UP: i32 = 0x0100_0013;
    pub const KEY_RIGHT: i32 = 0x0100_0014;
    pub const KEY_DOWN: i32 = 0x0100_0015;
    pub const KEY_PAGE_UP: i32 = 0x0100_0016;
    pub const KEY_PAGE_DOWN: i32 = 0x0100_0017;
    pub const KEY_SHIFT: i32 = 0x0100_0020;
    pub const KEY_CONTROL: i32 = 0x0100_0021;
    pub const KEY_META: i32 = 0x0100_0022;
    pub const KEY_ALT: i32 = 0x0100_0023;
    pub const KEY_F1: i32 = 0x0100_0030;
    pub const KEY_F24: i32 = 0x0100_0047;
    pub const KEY_Q: i32 = 0x51;

    pub const SHIFT: i32 = 0x0200_0000;
    pub const CONTROL: i32 = 0x0400_0000;
    pub const ALT: i32 = 0x0800_0000;
    pub const META: i32 = 0x1000_0000;
}

/// The key a recorder makes of a Qt key press (Qt::Key,
/// Qt::KeyboardModifiers), or empty when the press needs a modifier or is a
/// modifier itself.
pub fn recorded_key(key: i32, modifiers: i32, mac: bool) -> String {
    let named = match key {
        qt::KEY_SPACE => "space",
        qt::KEY_UP => "arrowup",
        qt::KEY_DOWN => "arrowdown",
        qt::KEY_LEFT => "arrowleft",
        qt::KEY_RIGHT => "arrowright",
        qt::KEY_RETURN | qt::KEY_ENTER => "enter",
        qt::KEY_TAB | qt::KEY_BACKTAB => "tab",
        qt::KEY_BACKSPACE => "backspace",
        qt::KEY_DELETE => "delete",
        qt::KEY_HOME => "home",
        qt::KEY_END => "end",
        qt::KEY_PAGE_UP => "pageup",
        qt::KEY_PAGE_DOWN => "pagedown",
        _ => "",
    };
    let token = if !named.is_empty() {
        named.to_owned()
    } else if (qt::KEY_F1..=qt::KEY_F24).contains(&key) {
        format!("f{}", key - qt::KEY_F1 + 1)
    } else if key > qt::KEY_SPACE && key <= qt::KEY_ASCII_TILDE {
        // Qt reports the shifted character; a keymap records the physical
        // key.
        let c = (key as u8 as char).to_ascii_lowercase();
        let unshifted = match c {
            '{' => '[',
            '}' => ']',
            '<' => ',',
            '>' => '.',
            '?' => '/',
            ':' => ';',
            '"' => '\'',
            '|' => '\\',
            '~' => '`',
            '!' => '1',
            '@' => '2',
            '#' => '3',
            '$' => '4',
            '%' => '5',
            '^' => '6',
            '&' => '7',
            '*' => '8',
            '(' => '9',
            ')' => '0',
            '_' => '-',
            '+' => '=',
            other => other,
        };
        unshifted.to_string()
    } else {
        return String::new();
    };
    // Qt's Control is Command on macOS, and its Meta is Control.
    let mut parts = Vec::new();
    if modifiers & qt::CONTROL != 0 {
        parts.push("mod");
    }
    if modifiers & qt::META != 0 {
        parts.push(if mac { "ctrl" } else { "meta" });
    }
    if modifiers & qt::ALT != 0 {
        parts.push("alt");
    }
    if modifiers & qt::SHIFT != 0 {
        parts.push("shift");
    }
    if parts.is_empty() {
        return String::new();
    }
    parts.push(&token);
    parts.join("+")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shortcuts_parse_as_written() {
        let s = parse_shortcut("Mod+Shift+[").unwrap();
        assert!(s.mod_ && s.shift && s.key == "[");
        assert_eq!(parse_shortcut("mod++").unwrap().key, "+");
        assert_eq!(parse_shortcut("ctrl+space").unwrap().key, " ");
        assert_eq!(parse_shortcut("esc").unwrap().key, "escape");
        assert!(parse_shortcut("mod+a+b").is_none());
        assert!(parse_shortcut("mod+shift").is_none());
        assert!(parse_shortcut("mod++a").is_none());
        assert_eq!(
            key_text(&parse_shortcut("shift+mod+esc").unwrap()),
            "mod+shift+esc"
        );
    }

    #[test]
    fn conditions_parse_evaluate_and_print() {
        let when = parse_when("a && !(b || c)").unwrap();
        assert_eq!(when_text(Some(&when)), "a && !(b || c)");
        let context: Context = [("a".to_owned(), true)].into();
        assert!(evaluate(Some(&when), &context));
        assert!(parse_when("a &&").is_none());
        assert!(parse_when("").is_none());
        assert!(parse_when("a & b").is_none());
        assert!(parse_when(&format!("{}a", "!".repeat(65))).is_none());
        assert!(parse_when(&format!("{}a", "!".repeat(64))).is_some());
        assert!(parse_when(&format!("{}a{}", "(".repeat(66), ")".repeat(66))).is_none());
        assert!(evaluate(parse_when("true").as_ref(), &Context::new()));
        assert!(!evaluate(
            parse_when("false || x").as_ref(),
            &Context::new()
        ));
    }

    #[test]
    fn sequences_and_labels_follow_the_platform() {
        let s = parse_shortcut("mod+shift+e").unwrap();
        assert_eq!(sequence(&s, false), "Ctrl+Shift+E");
        assert_eq!(sequence(&s, true), "Ctrl+Shift+E");
        assert_eq!(label(&s, false), "Ctrl+Shift+E");
        assert_eq!(label(&s, true), "⇧⌘E");
        let up = parse_shortcut("ctrl+arrowup").unwrap();
        assert_eq!(sequence(&up, true), "Meta+Up");
        assert_eq!(label(&up, false), "Ctrl+Up");
        assert_eq!(sequence(&parse_shortcut("shift+a").unwrap(), false), "");
        assert_eq!(
            sequence(&parse_shortcut("mod+f13").unwrap(), false),
            "Ctrl+F13"
        );
        assert_eq!(sequence(&parse_shortcut("mod+f25").unwrap(), false), "");
    }

    #[test]
    fn a_user_rule_replaces_its_commands_defaults() {
        let merged = merge(&[json!({"key": "mod+shift+b", "command": "sidebar.toggle"})]);
        let sidebar: Vec<_> = merged
            .iter()
            .filter(|b| b.command == "sidebar.toggle")
            .collect();
        assert_eq!(sidebar.len(), 1);
        assert_eq!(sidebar[0].rule.key, "mod+shift+b");
        assert_eq!(merged.last().unwrap().command, "sidebar.toggle");
        // Unknown commands and bad rules fall away; nothing left is the
        // defaults.
        assert_eq!(
            merge(&[json!({"key": "mod+b", "command": "nope"})]),
            default_bindings()
        );
        assert!(is_command("script.test-1.run"));
        assert!(!is_command("script.Test.run"));
        assert!(!is_command(&format!("script.{}.run", "a".repeat(25))));
    }

    #[test]
    fn the_last_binding_that_holds_wins() {
        let bindings = default_bindings();
        let mut context = Context::new();
        assert_eq!(resolve(bindings, "Ctrl+D", &context, false), "diff.toggle");
        context.insert("terminalFocus".into(), true);
        assert_eq!(
            resolve(bindings, "Ctrl+D", &context, false),
            "terminal.split"
        );
    }

    #[test]
    fn labels_for_commands_and_recorded_keys() {
        assert_eq!(
            command_label("terminal.splitVertical"),
            "Terminal: Split Vertical"
        );
        assert_eq!(
            command_label("script.run-tests.run"),
            "Run Script: Run Tests"
        );
        assert_eq!(
            command_label("thread.copyReference"),
            "Pull Request: Copy Link or Thread ID"
        );
        assert_eq!(
            recorded_key('{' as i32, qt::CONTROL | qt::SHIFT, false),
            "mod+shift+["
        );
        assert_eq!(recorded_key('A' as i32, 0, false), "");
        assert_eq!(recorded_key(qt::KEY_F1 + 11, qt::META, true), "ctrl+f12");
        assert_eq!(recorded_key(qt::KEY_SHIFT, qt::SHIFT, false), "");
    }
}
