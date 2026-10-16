//! A checkout's `hal-c2.json` (packages/contracts halC2ProjectFile.ts),
//! desktop-qt's `projectfile`: read as JSON that may carry comments and
//! trailing commas, and that either matches the format or is no file at all.

use crate::json::Json;

/// The file's name at the root of a checkout.
pub const NAME: &str = "hal-c2.json";

const MAX_SCRIPTS: usize = 50;
const MAX_PATH: usize = 512;

/// ProjectScriptIcon.
pub const ICONS: [&str; 6] = ["play", "test", "lint", "configure", "build", "debug"];

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Script {
    pub name: String,
    pub command: String,
    pub icon: String,
    pub run_on_worktree_create: bool,
    pub r#async: Option<bool>,
    pub preview_url: String,
    pub auto_open_preview: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct File {
    pub scripts: Vec<Script>,
    /// "local" or "worktree"; empty when the file does not say.
    pub default_thread_env_mode: String,
}

/// The text without `//` and `/* */` comments and without commas that end an
/// object or array, leaving strings as they are.
fn strict(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let at = |i: usize| chars.get(i).copied();
    let mut out = String::with_capacity(text.len());
    let mut in_string = false;
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if in_string {
            out.push(c);
            if c == '\\' && i + 1 < chars.len() {
                i += 1;
                out.push(chars[i]);
            } else if c == '"' {
                in_string = false;
            }
        } else if c == '"' {
            in_string = true;
            out.push(c);
        } else if c == '/' && at(i + 1) == Some('/') {
            while i < chars.len() && chars[i] != '\n' {
                i += 1;
            }
            out.push('\n');
            i += 1;
            continue;
        } else if c == '/' && at(i + 1) == Some('*') {
            i = block_end(&chars, i + 2);
            out.push(' ');
            continue;
        } else if c == ',' {
            // A comma only a closing bracket follows (past blanks and
            // comments) is dropped.
            let mut next = i + 1;
            while next < chars.len() {
                if chars[next].is_whitespace() {
                    next += 1;
                } else if chars[next] == '/' && at(next + 1) == Some('/') {
                    while next < chars.len() && chars[next] != '\n' {
                        next += 1;
                    }
                } else if chars[next] == '/' && at(next + 1) == Some('*') {
                    next = block_end(&chars, next + 2);
                } else {
                    break;
                }
            }
            if !matches!(at(next), Some('}' | ']')) {
                out.push(c);
            }
        } else {
            out.push(c);
        }
        i += 1;
    }
    out
}

/// Where a block comment whose body starts at `from` ends: past its `*/`, or
/// the end of the text when it never closes.
fn block_end(chars: &[char], from: usize) -> usize {
    (from..chars.len().saturating_sub(1))
        .find(|&i| chars[i] == '*' && chars[i + 1] == '/')
        .map_or(chars.len(), |i| i + 2)
}

/// A string field trimmed. `Err` when it is there and not a non-empty string
/// (or too long), or is missing and `required`; an optional field that is
/// missing is empty.
fn trimmed(object: &Json, key: &str, required: bool, max_length: usize) -> Result<String, ()> {
    let Some(value) = object.get(key) else {
        return if required { Err(()) } else { Ok(String::new()) };
    };
    let raw = value.as_str().ok_or(())?;
    if raw.is_empty() || (max_length > 0 && raw.encode_utf16().count() > max_length) {
        return Err(());
    }
    match raw.trim() {
        "" => Err(()),
        value => Ok(value.to_owned()),
    }
}

fn optional_bool(object: &Json, key: &str) -> Result<Option<bool>, ()> {
    match object.get(key) {
        None => Ok(None),
        Some(Json::Bool(b)) => Ok(Some(*b)),
        Some(_) => Err(()),
    }
}

/// The file, or nothing when it is not valid JSON or does not match the format.
pub fn parse(contents: &str) -> Option<File> {
    let root: Json = serde_json::from_str(&strict(contents)).ok()?;
    if !root.is_object() {
        return None;
    }
    read(&root).ok()
}

fn read(root: &Json) -> Result<File, ()> {
    let mut file = File::default();
    if root.get("$schema").is_some_and(|v| !v.is_string()) {
        return Err(());
    }
    trimmed(root, "iconPath", false, MAX_PATH)?;
    if let Some(mode) = root.get("defaultThreadEnvMode") {
        match mode.as_str() {
            Some(mode @ ("local" | "worktree")) => file.default_thread_env_mode = mode.into(),
            _ => return Err(()),
        }
    }
    if let Some(modes) = root.get("worktreeSubmodules")
        && !matches!(modes.as_str(), Some("recursive" | "top-level" | "none"))
    {
        return Err(());
    }
    if let Some(scripts) = root.get("scripts") {
        let scripts = scripts.as_array().ok_or(())?;
        if scripts.len() > MAX_SCRIPTS {
            return Err(());
        }
        for entry in scripts {
            if !entry.is_object() {
                return Err(());
            }
            let icon = match entry.get("icon") {
                None => "play",
                Some(icon) => icon.as_str().filter(|i| ICONS.contains(i)).ok_or(())?,
            };
            file.scripts.push(Script {
                name: trimmed(entry, "name", true, 0)?,
                command: trimmed(entry, "command", true, 0)?,
                icon: icon.into(),
                run_on_worktree_create: optional_bool(entry, "runOnWorktreeCreate")?
                    .unwrap_or(false),
                r#async: optional_bool(entry, "async")?,
                preview_url: trimmed(entry, "previewUrl", false, 0)?,
                auto_open_preview: optional_bool(entry, "autoOpenPreview")?.unwrap_or(false),
            });
        }
    }
    Ok(file)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_file_with_comments_and_trailing_commas_reads() {
        let file = parse(
            r#"{
  // the scripts
  "$schema": "https://example.test/schema.json",
  "defaultThreadEnvMode": "worktree", /* where new threads start */
  "scripts": [
    { "name": " Test ", "command": "mise run test", "icon": "test", "async": true, },
    { "name": "Dev", "command": "mise run dev", "previewUrl": "http://localhost:3000",
      "autoOpenPreview": true, "runOnWorktreeCreate": true },
  ],
}"#,
        )
        .unwrap();
        assert_eq!(file.default_thread_env_mode, "worktree");
        assert_eq!(file.scripts.len(), 2);
        assert_eq!(
            file.scripts[0],
            Script {
                name: "Test".into(),
                command: "mise run test".into(),
                icon: "test".into(),
                run_on_worktree_create: false,
                r#async: Some(true),
                preview_url: String::new(),
                auto_open_preview: false,
            }
        );
        let dev = &file.scripts[1];
        assert_eq!((dev.icon.as_str(), dev.r#async), ("play", None));
        assert_eq!(dev.preview_url, "http://localhost:3000");
        assert!(dev.auto_open_preview && dev.run_on_worktree_create);
    }

    #[test]
    fn comment_markers_inside_strings_are_text() {
        let file =
            parse(r#"{"scripts": [{"name": "a // b", "command": "echo '/* x */', \"q\",]"}]}"#)
                .unwrap();
        assert_eq!(file.scripts[0].name, "a // b");
        assert_eq!(file.scripts[0].command, "echo '/* x */', \"q\",]");
    }

    #[test]
    fn an_unclosed_comment_runs_to_the_end() {
        assert_eq!(parse("{} /* never closed"), Some(File::default()));
        assert_eq!(parse("{} // trailing"), Some(File::default()));
    }

    #[test]
    fn what_is_not_the_format_is_no_file() {
        for contents in [
            "",
            "[]",
            "{",
            r#"{"$schema": 1}"#,
            r#"{"iconPath": ""}"#,
            r#"{"iconPath": 3}"#,
            r#"{"defaultThreadEnvMode": "elsewhere"}"#,
            r#"{"worktreeSubmodules": "all"}"#,
            r#"{"scripts": {}}"#,
            r#"{"scripts": ["x"]}"#,
            r#"{"scripts": [{"command": "x"}]}"#,
            r#"{"scripts": [{"name": " ", "command": "x"}]}"#,
            r#"{"scripts": [{"name": "a", "command": "x", "icon": "party"}]}"#,
            r#"{"scripts": [{"name": "a", "command": "x", "async": "yes"}]}"#,
            r#"{"scripts": [{"name": "a", "command": "x", "previewUrl": ""}]}"#,
        ] {
            assert_eq!(parse(contents), None, "{contents}");
        }
    }

    #[test]
    fn the_limits_hold() {
        let path = "p".repeat(MAX_PATH);
        assert!(parse(&format!(r#"{{"iconPath": "{path}"}}"#)).is_some());
        assert!(parse(&format!(r#"{{"iconPath": "{path}p"}}"#)).is_none());
        let script = r#"{"name": "a", "command": "b"}"#;
        let scripts = |n: usize| format!(r#"{{"scripts": [{}]}}"#, vec![script; n].join(","));
        assert_eq!(
            parse(&scripts(MAX_SCRIPTS)).unwrap().scripts.len(),
            MAX_SCRIPTS
        );
        assert!(parse(&scripts(MAX_SCRIPTS + 1)).is_none());
    }
}
