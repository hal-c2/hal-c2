//! The capture shortcut kept in the compositor's own config, on Niri and
//! Hyprland, desktop-qt's CaptureShortcutConfig: the controller reviews the
//! change with the user before it is written, then writes exactly what was
//! reviewed.
//!
//! `preview` reads the config (and, on Niri, every file it includes),
//! refuses one that is not safe to edit, and proposes the edit; `apply`
//! writes only the last proposal, and only while none of the files read for
//! it has changed. The write goes through a temporary file beside the config
//! that Niri validates first; the original is kept as a backup, and Hyprland
//! reloads afterwards. One change at a time: a preview while one is saving
//! is refused.
//!
//! A refusal is the message the user reads, in the `Err`.

use std::sync::Arc;
use std::sync::LazyLock;

use regex::Regex;

const MAX_BYTES: usize = 1024 * 1024;
const MAX_FILES: usize = 64;
pub const NIRI_PATH: &str = "/com/hal_c2/SnapShot";
pub const NIRI_INTERFACE: &str = "com.hal_c2.SnapShot";

/// One of `hyprctl -j binds`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct HyprlandBind {
    pub modmask: i32,
    pub key: String,
    pub dispatcher: String,
    pub arg: String,
}

/// What the compositor is asked. The system's run `niri` and `hyprctl`;
/// tests stand in for them.
#[derive(Clone)]
pub struct Tools {
    /// `niri validate --config <path>` passes.
    pub validate_niri: Arc<dyn Fn(&str) -> bool + Send + Sync>,
    /// The binds Hyprland has, or none when it cannot say.
    pub hyprland_bindings: Arc<dyn Fn() -> Option<Vec<HyprlandBind>> + Send + Sync>,
    /// `hyprctl reload`, then `hyprctl configerrors`: what went wrong, or empty.
    pub reload_hyprland: Arc<dyn Fn() -> String + Send + Sync>,
}

impl Tools {
    pub fn system() -> Tools {
        Tools {
            validate_niri: Arc::new(|path| run("niri", &["validate", "--config", path]).is_some()),
            hyprland_bindings: Arc::new(|| {
                let output = run("hyprctl", &["-j", "binds"])?;
                let serde_json::Value::Array(values) = serde_json::from_slice(&output).ok()? else {
                    return None;
                };
                values
                    .iter()
                    .map(|bind| {
                        Some(HyprlandBind {
                            modmask: bind.get("modmask")?.as_f64()? as i32,
                            key: bind.get("key")?.as_str()?.to_owned(),
                            dispatcher: bind.get("dispatcher")?.as_str()?.to_owned(),
                            arg: bind.get("arg")?.as_str()?.to_owned(),
                        })
                    })
                    .collect()
            }),
            reload_hyprland: Arc::new(|| {
                if run("hyprctl", &["reload"]).is_none() {
                    return "Config saved, but Hyprland couldn't reload it. Run hyprctl reload."
                        .into();
                }
                match run("hyprctl", &["configerrors"]) {
                    Some(errors) if errors.trim_ascii().is_empty() => String::new(),
                    _ => "Config saved, but Hyprland reported config errors. Check hyprctl configerrors, then run hyprctl reload.".into(),
                }
            }),
        }
    }
}

/// A tool's run, bounded to five seconds: its stdout when it exited 0.
fn run(program: &str, arguments: &[&str]) -> Option<Vec<u8>> {
    use std::io::Read;
    use std::process::{Command, Stdio};
    use std::time::Duration;
    let mut child = Command::new(program)
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let pid = child.id();
    let mut stdout = child.stdout.take()?;
    let (sent, done) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut output = Vec::new();
        let read = (&mut stdout)
            .take(MAX_BYTES as u64 + 1)
            .read_to_end(&mut output);
        // Drain the rest so the tool never blocks on a full pipe.
        let _ = std::io::copy(&mut stdout, &mut std::io::sink());
        let status = child.wait();
        let _ = sent.send((read.is_ok(), output, status));
    });
    let (read, output, status) = match done.recv_timeout(Duration::from_secs(5)) {
        Ok(done) => done,
        Err(_) => {
            // The PID spawned above, still unreaped: the waiting thread holds it.
            #[cfg(unix)]
            unsafe {
                libc::kill(pid as libc::pid_t, libc::SIGKILL);
            }
            let _ = pid;
            let _ = done.recv_timeout(Duration::from_secs(1));
            return None;
        }
    };
    (read && output.len() <= MAX_BYTES && status.is_ok_and(|status| status.success()))
        .then_some(output)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Format {
    Niri,
    Hyprland,
    HyprlandLua,
}

/// A chord as compositor configs take it: a letter, digit or F1-F24 with
/// Ctrl, Alt or Super (and Shift).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Keys {
    /// Ctrl+Shift+2
    pub label: String,
    /// CTRL SHIFT
    pub modifiers: String,
    /// 2
    pub key: String,
    /// Hyprland's modmask.
    pub mask: i32,
}

/// The keys of a label, "Ctrl+Shift+2", or why a compositor cannot take them.
pub fn keys(input: &str) -> Result<Keys, String> {
    static KEY: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"^(?:[a-z0-9]|f(?:[1-9]|1[0-9]|2[0-4]))$").unwrap());
    let refused =
        || "Choose a letter, number, or function key with Ctrl, Alt, or Super.".to_owned();
    let input = if input.is_empty() {
        "Ctrl+Shift+2"
    } else {
        input
    };
    let parts: Vec<&str> = input.trim().split('+').collect();
    let (mut ctrl, mut alt, mut shift, mut meta, mut bad) = (false, false, false, false, false);
    for part in &parts[..parts.len() - 1] {
        match part.trim().to_lowercase().as_str() {
            "ctrl" | "control" => ctrl = true,
            "alt" | "option" => alt = true,
            "shift" => shift = true,
            "super" | "meta" | "cmd" | "win" => meta = true,
            // mod, or a word no compositor takes
            _ => bad = true,
        }
    }
    let name = parts[parts.len() - 1].trim().to_lowercase();
    if bad || !KEY.is_match(&name) || !(ctrl || alt || meta) {
        return Err(refused());
    }
    let modifiers: Vec<&str> = [
        (ctrl, "Ctrl"),
        (alt, "Alt"),
        (shift, "Shift"),
        (meta, "Super"),
    ]
    .into_iter()
    .filter_map(|(on, name)| on.then_some(name))
    .collect();
    let key = name.to_uppercase();
    let mut label = modifiers.clone();
    label.push(&key);
    Ok(Keys {
        label: label.join("+"),
        modifiers: modifiers.join(" ").to_uppercase(),
        key: key.clone(),
        mask: shift as i32 | (ctrl as i32) << 2 | (alt as i32) << 3 | (meta as i32) << 6,
    })
}

fn niri_binding(app_id: &str) -> String {
    format!(
        "Ctrl+Shift+2 repeat=false {{ spawn \"gdbus\" \"call\" \"--session\" \"--dest\" \"{app_id}.SnapShot\" \"--object-path\" \"{NIRI_PATH}\" \"--method\" \"{NIRI_INTERFACE}.Capture\"; }}"
    )
}

/// HAL-C2's binding on `keys` for a config of `format`.
pub fn binding(format: Format, app_id: &str, keys: &str) -> String {
    let Ok(chord) = self::keys(keys) else {
        return String::new();
    };
    let action = format!("{app_id}:capture-window");
    match format {
        Format::Niri => niri_binding(app_id).replace("Ctrl+Shift+2", &chord.label),
        Format::HyprlandLua => format!(
            "hl.bind(\"{}\", hl.dsp.global(\"{action}\"))",
            chord.label.to_uppercase().replace('+', " + ")
        ),
        Format::Hyprland => format!(
            "bind = {}, {}, global, {action}",
            chord.modifiers, chord.key
        ),
    }
}

/// The user's home, which the configs must stay inside.
pub fn home(env: &dyn Fn(&str) -> Option<String>) -> String {
    match env("HOME").filter(|home| !home.is_empty()) {
        Some(home) => home,
        #[allow(deprecated)]
        None => std::env::home_dir()
            .map(|home| home.to_string_lossy().into_owned())
            .unwrap_or_default(),
    }
}

fn config_home(env: &dyn Fn(&str) -> Option<String>) -> String {
    env("XDG_CONFIG_HOME")
        .filter(|xdg| !xdg.is_empty())
        .unwrap_or_else(|| home(env) + "/.config")
}

/// Where Niri reads its config by default.
pub fn niri_config_path(env: &dyn Fn(&str) -> Option<String>) -> String {
    env("NIRI_CONFIG")
        .filter(|configured| !configured.is_empty())
        .unwrap_or_else(|| config_home(env) + "/niri/config.kdl")
}

/// Where Hyprland reads its config by default.
pub fn hyprland_config_path(env: &dyn Fn(&str) -> Option<String>) -> String {
    let directory = config_home(env) + "/hypr/";
    let choose = |bindings: &str, main: &str| {
        if std::path::Path::new(&(directory.clone() + bindings)).exists() {
            directory.clone() + bindings
        } else {
            directory.clone() + main
        }
    };
    if std::path::Path::new(&(directory.clone() + "hyprland.lua")).exists() {
        choose("bindings.lua", "hyprland.lua")
    } else {
        choose("bindings.conf", "hyprland.conf")
    }
}

// --- KDL: just enough of it to find nodes and where they sit ---------------

#[derive(Clone, Debug)]
struct Token {
    value: String,
    start: usize,
    end: usize,
    quoted: bool,
}

#[derive(Clone, Debug)]
struct Node {
    name: String,
    header: Vec<Token>,
    children: Vec<Node>,
    start: usize,
    end: usize,
    close: Option<usize>,
}

const UNREADABLE_KDL: &str =
    "Couldn't read this Niri config. Use Advanced to configure it manually.";

fn kdl_space(c: char) -> bool {
    matches!(
        c,
        '\t' | ' ' | '\r' | '\u{FEFF}' | '\u{00A0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}'
    )
}

fn tokenize(source: &str) -> Option<Vec<Token>> {
    static CONTINUATION: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new("^\\\\[\\t \\r\u{00A0}\u{1680}\u{2000}-\u{200A}\u{202F}\u{205F}\u{3000}]*\\n")
            .unwrap()
    });
    static RAW: LazyLock<Regex> = LazyLock::new(|| Regex::new("^r(#{0,32})\"").unwrap());
    let mut tokens = Vec::new();
    let mut offset = 0;
    let size = source.len();
    let bytes = source.as_bytes();
    while offset < size {
        let start = offset;
        let rest = &source[offset..];
        let c = rest.chars().next()?;
        if kdl_space(c) {
            offset += c.len_utf8();
            continue;
        }
        if rest.starts_with("//") {
            offset = rest.find('\n').map_or(size, |end| offset + end);
            continue;
        }
        if rest.starts_with("/*") {
            offset += 2;
            let mut depth = 1;
            while depth > 0 && offset < size {
                let here = &source[offset..];
                if here.starts_with("/*") {
                    depth += 1;
                    offset += 2;
                } else if here.starts_with("*/") {
                    depth -= 1;
                    offset += 2;
                } else {
                    offset += here.chars().next()?.len_utf8();
                }
            }
            if depth > 0 {
                return None;
            }
            continue;
        }
        if let Some(found) = CONTINUATION.find(rest) {
            offset += found.end();
            continue;
        }
        if let Some(found) = RAW.captures(rest) {
            let opened = found.get(0)?.end();
            let terminator = format!("\"{}", &found[1]);
            let end = source[offset + opened..].find(&terminator)? + offset + opened;
            offset = end + terminator.len();
            tokens.push(Token {
                value: source[start + opened..end].to_owned(),
                start,
                end: offset,
                quoted: true,
            });
            continue;
        }
        if c == '"' {
            offset += 1;
            while offset < size && bytes[offset] != b'"' {
                if bytes[offset] == b'\\' {
                    offset += 1;
                }
                offset += 1;
            }
            if offset >= size {
                return None;
            }
            offset += 1;
            // KDL's unicode escapes differ from JSON's; names needing those stay on the manual path.
            let parsed: Vec<serde_json::Value> =
                serde_json::from_str(&format!("[{}]", &source[start..offset])).ok()?;
            let value = parsed.first()?.as_str()?.to_owned();
            tokens.push(Token {
                value,
                start,
                end: offset,
                quoted: true,
            });
            continue;
        }
        if rest.starts_with("/-") {
            offset += 2;
        } else if "{};\n=()".contains(c) {
            offset += 1;
        } else {
            while offset < size {
                let here = &source[offset..];
                let c = here.chars().next()?;
                if c.is_whitespace() || kdl_space(c) || "{};=\"()".contains(c) {
                    break;
                }
                if here.starts_with("//") || here.starts_with("/*") || here.starts_with("/-") {
                    break;
                }
                offset += c.len_utf8();
            }
        }
        if offset == start {
            return None;
        }
        tokens.push(Token {
            value: source[start..offset].to_owned(),
            start,
            end: offset,
            quoted: false,
        });
    }
    Some(tokens)
}

struct Parser<'a> {
    tokens: &'a [Token],
    cursor: usize,
    failed: bool,
}

impl Parser<'_> {
    fn is(&self, index: usize, value: &str) -> bool {
        self.tokens
            .get(index)
            .is_some_and(|token| !token.quoted && token.value == value)
    }

    fn nodes(&mut self, nested: bool) -> Vec<Node> {
        let mut result = Vec::new();
        while self.cursor < self.tokens.len() && !self.failed {
            if self.is(self.cursor, "\n") || self.is(self.cursor, ";") {
                self.cursor += 1;
                continue;
            }
            if self.is(self.cursor, "}") {
                if !nested {
                    self.failed = true;
                }
                return result;
            }
            let disabled = self.is(self.cursor, "/-");
            if disabled {
                self.cursor += 1;
            }
            if self.cursor >= self.tokens.len() {
                self.failed = true;
                return result;
            }
            let name = self.tokens[self.cursor].clone();
            self.cursor += 1;
            if !name.quoted && ["{", "}", "=", ";", "\n", "("].contains(&name.value.as_str()) {
                self.failed = true;
                return result;
            }
            let mut node = Node {
                name: name.value.clone(),
                start: name.start,
                end: name.end,
                header: vec![name],
                children: Vec::new(),
                close: None,
            };
            while self.cursor < self.tokens.len()
                && !self.is(self.cursor, "\n")
                && !self.is(self.cursor, ";")
                && !self.is(self.cursor, "}")
            {
                let token = self.tokens[self.cursor].clone();
                self.cursor += 1;
                if !token.quoted && token.value == "{" {
                    node.children = self.nodes(true);
                    if self.failed {
                        return result;
                    }
                    if !self.is(self.cursor, "}") {
                        self.failed = true;
                        return result;
                    }
                    node.close = Some(self.tokens[self.cursor].start);
                    node.end = self.tokens[self.cursor].end;
                    self.cursor += 1;
                    break;
                }
                node.end = token.end;
                node.header.push(token);
            }
            if !disabled {
                result.push(node);
            }
        }
        if nested {
            self.failed = true;
        }
        result
    }
}

fn read_kdl(source: &str) -> Result<Vec<Node>, String> {
    let tokens = tokenize(source).ok_or(UNREADABLE_KDL)?;
    let mut parser = Parser {
        tokens: &tokens,
        cursor: 0,
        failed: false,
    };
    let nodes = parser.nodes(false);
    if parser.failed {
        return Err(UNREADABLE_KDL.into());
    }
    Ok(nodes)
}

// --- Edits -------------------------------------------------------------------

fn same_keys(left: &str, right: &str) -> bool {
    matches!((keys(left), keys(right)), (Ok(a), Ok(b)) if a.label == b.label)
}

/// The one binds block, none when there is none; an error when there are
/// two or one never closes.
fn niri_binds(source: &str) -> Result<Option<Node>, String> {
    let mut block = None;
    for node in read_kdl(source)? {
        if node.name != "binds" {
            continue;
        }
        if block.is_some() || node.close.is_none() {
            return Err(
                "This Niri config has an unexpected binds section. Check it in Advanced.".into(),
            );
        }
        block = Some(node);
    }
    Ok(block)
}

fn values(header: &[Token]) -> Vec<&str> {
    header.iter().map(|token| token.value.as_str()).collect()
}

fn niri_capture_node(node: &Node, app_id: &str) -> bool {
    let Ok(parsed) = read_kdl(&binding(Format::Niri, app_id, "Ctrl+Shift+2")) else {
        return false;
    };
    let Some(expected) = parsed.first().and_then(|node| node.children.first()) else {
        return false;
    };
    node.children.len() == 1
        && node.children[0].children.is_empty()
        && values(&node.children[0].header) == values(&expected.header)
}

#[derive(Clone, Debug)]
struct Range {
    start: usize,
    end: usize,
    keys: String,
    action: String,
}

fn hyprland_binds(source: &str, lua: bool) -> Vec<Range> {
    static LEGACY: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"^\s*bind[a-z]*\s*=\s*([^,]*),\s*([^,]*),\s*([^,]*),\s*(.*?)\s*(?:#.*)?$")
            .unwrap()
    });
    static MODERN: LazyLock<fancy_regex::Regex> =
        LazyLock::new(|| fancy_regex::Regex::new(r#"^\s*hl\.bind\(\s*(["'])(.*?)\1\s*,"#).unwrap());
    static GLOBAL: LazyLock<fancy_regex::Regex> = LazyLock::new(|| {
        fancy_regex::Regex::new(
            r#"^\s*hl\.dsp\.global\(\s*(["'])(.*?)\1\s*\)\s*\)\s*;?\s*(?:--.*)?$"#,
        )
        .unwrap()
    });
    static SPACES: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s+").unwrap());
    let mut bindings = Vec::new();
    let mut start = 0;
    while start < source.len() {
        let end = source[start..]
            .find('\n')
            .map_or(source.len(), |newline| start + newline + 1);
        let trimmed = source[start..end].trim_end();
        if !lua {
            if let Some(found) = LEGACY.captures(trimmed) {
                bindings.push(Range {
                    start,
                    end,
                    keys: format!(
                        "{}+{}",
                        SPACES.replace_all(found[1].trim(), "+"),
                        found[2].trim()
                    ),
                    action: if found[3].trim() == "global" {
                        found[4].trim().to_owned()
                    } else {
                        String::new()
                    },
                });
            }
        } else if let Ok(Some(found)) = MODERN.captures(trimmed) {
            // Any action holds the keys; only a global on one line is HAL-C2's to replace.
            let rest = &trimmed[found.get(0).map_or(0, |m| m.end())..];
            let action = match GLOBAL.captures(rest) {
                Ok(Some(action)) => action[2].to_owned(),
                _ => String::new(),
            };
            bindings.push(Range {
                start,
                end,
                keys: found[2].to_owned(),
                action,
            });
        }
        start = end;
    }
    bindings
}

struct Include {
    path: String,
    optional: bool,
}

fn niri_includes(source: &str) -> Result<Vec<Include>, String> {
    let mut includes = Vec::new();
    for node in read_kdl(source)? {
        if node.name != "include" {
            continue;
        }
        let header = &node.header;
        let path = (1..header.len())
            .find(|&i| header[i].quoted && header[i - 1].value != "=")
            .map(|i| header[i].value.clone())
            .unwrap_or_default();
        if path.is_empty() {
            return Err("Couldn't resolve a Niri include. Choose the config in Advanced.".into());
        }
        let optional = header
            .windows(3)
            .any(|w| w[0].value == "optional" && w[1].value == "=" && w[2].value == "true");
        includes.push(Include { path, optional });
    }
    Ok(includes)
}

/// Whether `keys` is bound to something else in `source`'s binds.
fn niri_conflict(source: &str, app_id: &str, keys: &str) -> Result<bool, String> {
    let Some(block) = niri_binds(source)? else {
        return Ok(false);
    };
    Ok(block
        .children
        .iter()
        .any(|node| same_keys(&node.name, keys) && !niri_capture_node(node, app_id)))
}

fn remove_ranges(source: &str, mut ranges: Vec<Range>) -> String {
    ranges.sort_by_key(|range| std::cmp::Reverse(range.start));
    let mut result = source.to_owned();
    for range in ranges {
        let line_start = source[..range.start].rfind('\n').map_or(0, |i| i + 1);
        let line_end = source[range.end..]
            .find('\n')
            .map_or(source.len(), |i| range.end + i);
        let whole_line = source[line_start..range.start].trim().is_empty()
            && source[range.end..line_end].trim().is_empty();
        let from = if whole_line { line_start } else { range.start };
        let to = if whole_line {
            (line_end + 1).min(source.len())
        } else {
            range.end
        };
        result.replace_range(from..to, "");
    }
    result
}

struct Edit {
    after: String,
    shortcut: String,
}

fn edit(
    source: &str,
    format: Format,
    app_id: &str,
    install: bool,
    requested: &str,
) -> Result<Edit, String> {
    static RETURNS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?m)^\s*return\b").unwrap());
    static LONG_STRING: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\[=*\[").unwrap());
    static VALID_ID: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[A-Za-z0-9_.-]+$").unwrap());
    if !VALID_ID.is_match(app_id) {
        return Err("Invalid capture application ID.".into());
    }
    if format == Format::HyprlandLua && (RETURNS.is_match(source) || LONG_STRING.is_match(source)) {
        return Err(
            "This Lua config needs a manual edit. Choose your bindings file or use manual setup in Advanced.".into(),
        );
    }
    let niri = format == Format::Niri;
    let lua = format == Format::HyprlandLua;
    let action = format!("{app_id}:capture-window");
    let existing: Vec<Range> = if niri {
        niri_binds(source)?
            .map(|block| {
                block
                    .children
                    .iter()
                    .filter(|node| niri_capture_node(node, app_id))
                    .map(|node| Range {
                        start: node.start,
                        end: node.end,
                        keys: node.name.clone(),
                        action: String::new(),
                    })
                    .collect()
            })
            .unwrap_or_default()
    } else {
        hyprland_binds(source, lua)
            .into_iter()
            .filter(|bind| bind.action == action)
            .collect()
    };
    let wanted = if !requested.is_empty() {
        requested.to_owned()
    } else {
        existing
            .first()
            .map(|range| range.keys.clone())
            .unwrap_or_default()
    };
    // Removal goes by the action, whatever keys the user gave it.
    if !install {
        let shortcut = keys(&wanted).map_or(wanted, |chord| chord.label);
        return Ok(Edit {
            after: remove_ranges(source, existing),
            shortcut,
        });
    }
    let label = keys(&wanted)?.label;
    if existing.len() == 1 && same_keys(&existing[0].keys, &label) {
        return Ok(Edit {
            after: source.to_owned(),
            shortcut: label,
        });
    }
    let mut after = remove_ranges(source, existing);
    let conflict = if niri {
        niri_conflict(&after, app_id, &label)?
    } else {
        hyprland_binds(&after, lua)
            .iter()
            .any(|bind| same_keys(&bind.keys, &label))
    };
    if conflict {
        return Err(format!(
            "{label} is already used in this config. Choose another shortcut."
        ));
    }
    let newline = if source.contains("\r\n") {
        "\r\n"
    } else {
        "\n"
    };
    let line = binding(format, app_id, &label);
    let separator = if !after.is_empty() && !after.ends_with('\n') {
        newline
    } else {
        ""
    };
    if niri {
        match niri_binds(&after)?.and_then(|block| block.close) {
            Some(close) => {
                let line_start = after[..close].rfind('\n').map_or(0, |i| i + 1);
                let indent = after[line_start..close].to_owned();
                if indent.trim().is_empty() {
                    after.insert_str(line_start, &format!("{indent}    {line}{newline}"));
                } else {
                    after.insert_str(close, &format!("{newline}    {line}{newline}"));
                }
            }
            None => {
                after +=
                    &format!("{separator}{newline}binds {{{newline}    {line}{newline}}}{newline}")
            }
        }
        read_kdl(&after)?;
    } else {
        // Never inside a Lua block or string, nor after an early return: at the end.
        after += &format!("{separator}{newline}{line}{newline}");
    }
    Ok(Edit {
        after,
        shortcut: label,
    })
}

// --- Files -------------------------------------------------------------------

#[derive(Clone, Debug)]
struct File {
    path: String,
    resolved_path: String,
    text: String,
    bytes: Vec<u8>,
    inode: u64,
    mode: u32,
    uid: u32,
}

enum ReadError {
    Missing,
    Unreadable,
    /// Too big or not text: the message says which.
    Refused(String),
}

/// The file at `path`, read without following a link at its end (realpath
/// first) or blocking on a FIFO.
#[cfg(unix)]
fn read_file(path: &str) -> Result<File, ReadError> {
    use std::io::Read;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    let too_big = || ReadError::Refused("Choose a config file smaller than 1 MB.".into());
    let resolved = std::fs::canonicalize(path).map_err(|e| {
        if e.kind() == std::io::ErrorKind::NotFound {
            ReadError::Missing
        } else {
            ReadError::Unreadable
        }
    })?;
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW)
        .open(&resolved)
        .map_err(|_| ReadError::Unreadable)?;
    let info = file.metadata().map_err(|_| ReadError::Unreadable)?;
    if !info.is_file() || info.len() > MAX_BYTES as u64 {
        return Err(too_big());
    }
    let mut bytes = Vec::new();
    (&mut file)
        .take(MAX_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| ReadError::Unreadable)?;
    if bytes.len() > MAX_BYTES {
        return Err(too_big());
    }
    let body = bytes.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(&bytes);
    let text = match std::str::from_utf8(body) {
        Ok(text) if !text.contains('\0') => text.to_owned(),
        _ => return Err(ReadError::Refused("Choose a text config file.".into())),
    };
    Ok(File {
        path: path.to_owned(),
        resolved_path: resolved.to_string_lossy().into_owned(),
        text,
        bytes,
        inode: info.ino(),
        mode: info.mode(),
        uid: info.uid(),
    })
}

#[cfg(not(unix))]
fn read_file(_path: &str) -> Result<File, ReadError> {
    Err(ReadError::Unreadable)
}

fn exists(path: &str) -> bool {
    match std::fs::symlink_metadata(path) {
        Ok(_) => true,
        Err(e) => e.kind() != std::io::ErrorKind::NotFound,
    }
}

/// Writes `bytes` to a new file at `path` with `mode`; false if it exists.
#[cfg(unix)]
fn write_new(path: &str, bytes: &[u8], mode: u32) -> bool {
    use std::io::Write;
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    let Ok(mut file) = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
    else {
        return false;
    };
    // The umask narrowed the mode it was created with.
    let ok = file.write_all(bytes).is_ok()
        && file
            .set_permissions(std::fs::Permissions::from_mode(mode))
            .is_ok()
        && file.sync_all().is_ok();
    drop(file);
    if !ok {
        let _ = std::fs::remove_file(path);
    }
    ok
}

/// An id no other preview or temporary file shares.
fn uuid() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNT: AtomicU64 = AtomicU64::new(0);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    format!(
        "{:016x}-{:08x}-{:x}",
        now as u64,
        std::process::id(),
        COUNT.fetch_add(1, Ordering::Relaxed)
    )
}

/// `path` with `.`, `..` and repeated slashes taken out, as QDir::cleanPath.
fn clean_path(path: &str) -> String {
    let absolute = path.starts_with('/');
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." if parts.last().is_some_and(|last| *last != "..") => {
                parts.pop();
            }
            ".." if absolute => {}
            part => parts.push(part),
        }
    }
    let joined = parts.join("/");
    match (absolute, joined.is_empty()) {
        (true, _) => format!("/{joined}"),
        (false, true) => ".".into(),
        (false, false) => joined,
    }
}

/// The absolute directory `path` sits in.
fn directory_of(path: &str) -> String {
    let path = if path.starts_with('/') {
        path.to_owned()
    } else {
        std::env::current_dir()
            .map(|cwd| format!("{}/{path}", cwd.to_string_lossy()))
            .unwrap_or_else(|_| path.to_owned())
    };
    let clean = clean_path(&path);
    match clean.rfind('/') {
        Some(0) => "/".into(),
        Some(slash) => clean[..slash].to_owned(),
        None => ".".into(),
    }
}

// --- Review and save ---------------------------------------------------------

/// Which config, on which compositor, for which app.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Target {
    /// niri | hyprland
    pub desktop: String,
    pub path: String,
    pub app_id: String,
}

/// A change proposed to the config, for the user to review.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Preview {
    pub id: String,
    pub path: String,
    pub resolved_path: String,
    pub before: String,
    pub after: String,
    pub shortcut: String,
    pub install: bool,
}

/// A change written.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Applied {
    pub backup_path: String,
    pub warning: String,
}

struct Pending {
    preview: Preview,
    target: Target,
    files: Vec<File>,
    missing: Vec<String>,
    check_hyprland_keys: bool,
}

/// Reads, edits and writes one config at a time, from a thread of the
/// controller's.
pub struct Config {
    home: String,
    tools: Tools,
    applying: bool,
    pending: Option<Pending>,
}

impl Config {
    pub fn new(home: String, tools: Tools) -> Config {
        Config {
            home,
            tools,
            applying: false,
            pending: None,
        }
    }

    fn check_hyprland_keys(&self, app_id: &str, shortcut: &str) -> Result<(), String> {
        let chord = keys(shortcut)?;
        let Some(bindings) = (self.tools.hyprland_bindings)() else {
            return Err("Couldn't check Hyprland's current shortcuts. Try again from your Hyprland session.".into());
        };
        let ours = format!("{app_id}:capture-window");
        if bindings.iter().any(|bind| {
            bind.modmask == chord.mask
                && bind.key.to_uppercase() == chord.key
                && !(bind.dispatcher == "global" && bind.arg == ours)
        }) {
            return Err(format!(
                "{} is already used by Hyprland. Choose another shortcut.",
                chord.label
            ));
        }
        Ok(())
    }

    pub fn preview(
        &mut self,
        target: &Target,
        install: bool,
        requested: &str,
    ) -> Result<Preview, String> {
        if self.applying {
            return Err("Wait for the current config change to finish.".into());
        }
        self.pending = None;
        let root = match read_file(&target.path) {
            Ok(root) => root,
            // Too big or not text says so; anything else is the file that can't be read.
            Err(ReadError::Refused(problem)) => return Err(problem),
            Err(_) => {
                return Err(
                    "Couldn't read your settings file. Choose a different file in Advanced.".into(),
                );
            }
        };
        #[cfg(unix)]
        let ours = root.uid == unsafe { libc::getuid() };
        #[cfg(not(unix))]
        let ours = false;
        if !ours || root.resolved_path.contains("/omarchy/default/") {
            return Err("Choose your own config, not system or Omarchy defaults.".into());
        }
        let niri = target.desktop == "niri";
        let format = if niri {
            Format::Niri
        } else if target.path.ends_with(".lua") {
            Format::HyprlandLua
        } else {
            Format::Hyprland
        };
        let extension = match format {
            Format::Niri => ".kdl",
            Format::HyprlandLua => ".lua",
            Format::Hyprland => ".conf",
        };
        if !target.path.ends_with(extension) {
            return Err("Choose a .kdl Niri config or a .conf/.lua Hyprland config.".into());
        }
        let edited = edit(&root.text, format, &target.app_id, install, requested)?;
        // Lua binds show up in Hyprland as opaque callbacks, our own unchanged one too.
        let hyprland_keys = install
            && (format == Format::Hyprland
                || (format == Format::HyprlandLua && edited.after != root.text));
        let mut files = vec![root.clone()];
        let mut absent = Vec::new();
        if niri {
            self.visit(
                target,
                install,
                &edited.shortcut,
                0,
                0,
                &mut files,
                &mut absent,
            )?;
        } else if hyprland_keys {
            self.check_hyprland_keys(&target.app_id, &edited.shortcut)?;
        }
        let preview = Preview {
            id: uuid(),
            path: root.path,
            resolved_path: root.resolved_path,
            before: root.text,
            after: edited.after,
            shortcut: edited.shortcut,
            install,
        };
        self.pending = Some(Pending {
            preview: preview.clone(),
            target: target.clone(),
            files,
            missing: absent,
            check_hyprland_keys: hyprland_keys,
        });
        Ok(preview)
    }

    /// Reads every file `files[index]` includes, depth first, into `files`.
    #[allow(clippy::too_many_arguments)]
    fn visit(
        &self,
        target: &Target,
        install: bool,
        shortcut: &str,
        index: usize,
        depth: usize,
        files: &mut Vec<File>,
        absent: &mut Vec<String>,
    ) -> Result<(), String> {
        static GLOB: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[*?\[\]]").unwrap());
        let total: usize = files.iter().map(|file| file.bytes.len()).sum();
        if depth > 10 || files.len() > MAX_FILES || total > MAX_BYTES {
            return Err(
                "This config has too many included files. Use manual setup in Advanced.".into(),
            );
        }
        let file = files[index].clone();
        for include in niri_includes(&file.text)? {
            if include.path.contains('$') || GLOB.is_match(&include.path) {
                return Err(
                    "This config uses a dynamic include. Use manual setup in Advanced.".into(),
                );
            }
            let path = if let Some(rest) = include.path.strip_prefix("~/") {
                clean_path(&format!("{}/{rest}", self.home))
            } else if include.path.starts_with('/') {
                clean_path(&include.path)
            } else {
                clean_path(&format!("{}/{}", directory_of(&file.path), include.path))
            };
            let child = match read_file(&path) {
                Ok(child) => child,
                Err(ReadError::Missing) if include.optional => {
                    absent.push(path);
                    continue;
                }
                Err(_) => {
                    return Err(
                        "Couldn't read an included Niri config. Check its location in Advanced."
                            .into(),
                    );
                }
            };
            if files
                .iter()
                .any(|item| item.resolved_path == child.resolved_path)
            {
                continue;
            }
            if install && niri_conflict(&child.text, &target.app_id, shortcut)? {
                return Err(format!(
                    "{shortcut} is already used in {}. Choose another shortcut.",
                    child.path
                ));
            }
            files.push(child);
            let next = files.len() - 1;
            self.visit(target, install, shortcut, next, depth + 1, files, absent)?;
        }
        Ok(())
    }

    fn unchanged(pending: &Pending) -> Result<(), String> {
        if pending.missing.iter().any(|path| exists(path)) {
            return Err(
                "Your config changed since this preview. Review changes again before saving."
                    .into(),
            );
        }
        for original in &pending.files {
            let same = read_file(&original.path).is_ok_and(|current| {
                current.resolved_path == original.resolved_path
                    && current.inode == original.inode
                    && current.mode == original.mode
                    && current.bytes == original.bytes
            });
            if !same {
                return Err(
                    "Your config changed since this preview. Nothing was saved. Review changes again before saving."
                        .into(),
                );
            }
        }
        Ok(())
    }

    pub fn apply(&mut self, id: &str, desktop: &str) -> Result<Applied, String> {
        let current = self
            .pending
            .as_ref()
            .is_some_and(|pending| pending.preview.id == id && pending.target.desktop == desktop);
        if self.applying || !current {
            return Err("This preview expired. Review changes again before saving.".into());
        }
        let pending = self.pending.take().expect("checked above");
        self.applying = true;
        let applied = self.write(&pending, desktop);
        self.applying = false;
        applied
    }

    #[cfg(unix)]
    fn write(&self, pending: &Pending, desktop: &str) -> Result<Applied, String> {
        let preview = &pending.preview;
        let root = &pending.files[0];
        Self::unchanged(pending)?;
        if pending.check_hyprland_keys {
            self.check_hyprland_keys(&pending.target.app_id, &preview.shortcut)?;
        }
        if preview.before == preview.after {
            return Ok(Applied::default());
        }
        let directory = directory_of(&root.resolved_path);
        let name = format!(".hal-c2-capture-{}.tmp", uuid());
        let temporary = format!("{directory}/{name}");
        let failed_write = || "Couldn't write your config. Nothing was changed.".to_owned();
        if !write_new(&temporary, preview.after.as_bytes(), root.mode & 0o777) {
            return Err(failed_write());
        }
        struct Unstage<'a> {
            path: &'a str,
            staged: bool,
        }
        impl Drop for Unstage<'_> {
            fn drop(&mut self) {
                if self.staged {
                    let _ = std::fs::remove_file(self.path);
                }
            }
        }
        let mut unstage = Unstage {
            path: &temporary,
            staged: true,
        };
        if desktop == "niri" {
            // Niri resolves includes against the selected path, not a dotfile link's target.
            let validation = format!("{}/{name}", directory_of(&root.path));
            let valid = if clean_path(&validation) == clean_path(&temporary) {
                (self.tools.validate_niri)(&temporary)
            } else if std::os::unix::fs::symlink(&temporary, &validation).is_ok() {
                let valid = (self.tools.validate_niri)(&validation);
                let _ = std::fs::remove_file(&validation);
                valid
            } else {
                false
            };
            if !valid {
                return Err(
                    "Niri couldn't validate the proposed config. Nothing was changed. Check your config in Advanced."
                        .into(),
                );
            }
        }
        Self::unchanged(pending)?;
        let backup = format!("{}.hal-c2-capture-backup-{}", root.resolved_path, uuid());
        if !write_new(&backup, &root.bytes, 0o600)
            || std::fs::rename(&temporary, &root.resolved_path).is_err()
        {
            return Err(failed_write());
        }
        unstage.staged = false;
        let warning = if desktop == "hyprland" {
            (self.tools.reload_hyprland)()
        } else {
            String::new()
        };
        Ok(Applied {
            backup_path: backup,
            warning,
        })
    }

    #[cfg(not(unix))]
    fn write(&self, _pending: &Pending, _desktop: &str) -> Result<Applied, String> {
        Err("Config setup requires a Niri or Hyprland session.".into())
    }

    pub fn applying(&self) -> bool {
        self.applying
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_read_labels_and_masks() {
        let chord = keys("ctrl+shift+2").unwrap();
        assert_eq!(chord.label, "Ctrl+Shift+2");
        assert_eq!(chord.modifiers, "CTRL SHIFT");
        assert_eq!(chord.mask, 5);
        assert_eq!(keys("").unwrap().label, "Ctrl+Shift+2");
        assert!(keys("Shift+2").is_err());
        assert!(keys("Ctrl+Mod+2").is_err());
        assert_eq!(keys("Super+F12").unwrap().label, "Super+F12");
    }

    #[test]
    fn niri_inserts_into_the_binds_block_and_removes_it_again() {
        let source = "binds {\n    Mod+T { spawn \"foot\"; }\n}\n";
        let added = edit(source, Format::Niri, "hal-c2", true, "Ctrl+Alt+K").unwrap();
        assert_eq!(
            added.after,
            format!(
                "binds {{\n    Mod+T {{ spawn \"foot\"; }}\n    {}\n}}\n",
                binding(Format::Niri, "hal-c2", "Ctrl+Alt+K")
            )
        );
        let removed = edit(&added.after, Format::Niri, "hal-c2", false, "").unwrap();
        assert_eq!(removed.after, source);
        assert_eq!(removed.shortcut, "Ctrl+Alt+K");
        assert!(edit(source, Format::Niri, "hal-c2", true, "Mod+T").is_err());
    }

    #[test]
    fn hyprland_appends_and_finds_its_own_bind() {
        let source = "bind = SUPER, T, exec, foot";
        let added = edit(source, Format::Hyprland, "hal-c2", true, "").unwrap();
        assert_eq!(
            added.after,
            "bind = SUPER, T, exec, foot\n\nbind = CTRL SHIFT, 2, global, hal-c2:capture-window\n"
        );
        assert!(edit(source, Format::Hyprland, "hal-c2", true, "Super+T").is_err());
        let lua = edit("", Format::HyprlandLua, "hal-c2", true, "").unwrap();
        assert_eq!(
            lua.after,
            "\nhl.bind(\"CTRL + SHIFT + 2\", hl.dsp.global(\"hal-c2:capture-window\"))\n"
        );
        let removed = edit(&lua.after, Format::HyprlandLua, "hal-c2", false, "").unwrap();
        assert_eq!(removed.after, "\n");
    }

    #[test]
    fn kdl_refuses_what_it_cannot_read() {
        assert!(read_kdl("binds {").is_err());
        assert!(read_kdl("}").is_err());
        assert!(read_kdl("/* open").is_err());
        assert_eq!(
            read_kdl("a r#\"x\"# \"y\\n\" // c\n/-b\nc").unwrap().len(),
            2
        );
    }

    #[test]
    fn clean_path_folds_dots() {
        assert_eq!(clean_path("/a/./b/../c//d"), "/a/c/d");
        assert_eq!(clean_path("/.."), "/");
    }
}
