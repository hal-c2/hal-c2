//! The program a shell command runs, for a live row's "Ran git"
//! (desktop-qt's CommandLabel, a port of client-runtime's
//! work-log/commandLabel.ts). It reads the command as a shell would only as
//! far as naming its program needs: quotes, escapes, substitutions,
//! comments, heredocs and top-level separators. Anything it cannot read
//! with confidence names no program.

use std::collections::HashMap;
use std::sync::LazyLock;

use regex::Regex;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Context {
    Exec,
    Shell,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Wrapper {
    None,
    Env,
    Sudo,
}

const MAX_COMMAND_SEGMENTS: i32 = 64;

const SHELL_PROGRAMS: &[&str] = &["sh", "bash", "zsh", "dash", "ash", "ksh", "fish"];
const WINDOWS_SHELL_PROGRAMS: &[&str] = &[
    "cmd",
    "cmd.exe",
    "powershell",
    "powershell.exe",
    "pwsh",
    "pwsh.exe",
];
const SHELL_OPTIONS_WITH_VALUE: &[&str] = &["-o", "-O", "--rcfile", "--init-file"];
const SHELL_COMMAND_WRAPPERS: &[&str] = &["builtin", "command", "exec"];
const SHELL_PRECOMMAND_MODIFIERS: &[&str] = &["nocorrect", "noglob", "time"];
const POWER_SHELL_SETUP_PROGRAMS: &[&str] = &["pop-location", "push-location", "set-location"];
const POWER_SHELL_FLAGS: &[&str] = &["-mta", "-nologo", "-noninteractive", "-noprofile", "-sta"];
const POWER_SHELL_OPTIONS_WITH_VALUE: &[&str] = &[
    "-configurationname",
    "-executionpolicy",
    "-inputformat",
    "-outputformat",
    "-version",
    "-windowstyle",
    "-workingdirectory",
];
const START_PROCESS_FLAGS: &[&str] = &[
    "-confirm",
    "-debug",
    "-loaduserprofile",
    "-nonewwindow",
    "-passthru",
    "-usenewenvironment",
    "-verbose",
    "-wait",
    "-whatif",
];
const START_PROCESS_OPTIONS_WITH_VALUE: &[&str] = &[
    "-argumentlist",
    "-credential",
    "-environment",
    "-erroraction",
    "-errorvariable",
    "-informationaction",
    "-informationvariable",
    "-outbuffer",
    "-outvariable",
    "-pipelinevariable",
    "-progressaction",
    "-redirectstandarderror",
    "-redirectstandardinput",
    "-redirectstandardoutput",
    "-verb",
    "-warningaction",
    "-warningvariable",
    "-windowstyle",
    "-workingdirectory",
];
const SKIPPABLE_SUDO_PROBES: &[&str] = &["[", "[[", "test", "true"];
const NON_PROGRAM_PREFIX: &str = "<>(){}[];|&$`#!%@:";
const NON_PROGRAM_SUFFIX: &str = "){]}`";

/// Shell syntax or shell-local control flow, not a useful program name:
/// "command" is less misleading than "Ran if", "Ran [" or "Ran function".
const NON_DESCRIPTIVE_PROGRAMS: &[&str] = &[
    "!",
    "#",
    ".",
    ":",
    "[",
    "[[",
    "alias",
    "and",
    "autoload",
    "begin",
    "bg",
    "bind",
    "bindkey",
    "break",
    "builtin",
    "caller",
    "case",
    "catch",
    "cd",
    "command",
    "compgen",
    "complete",
    "compopt",
    "continue",
    "coproc",
    "declare",
    "dirs",
    "disown",
    "do",
    "done",
    "elif",
    "else",
    "enable",
    "end",
    "esac",
    "eval",
    "exec",
    "exit",
    "export",
    "false",
    "fc",
    "fg",
    "fi",
    "finally",
    "for",
    "foreach",
    "function",
    "getopts",
    "history",
    "if",
    "in",
    "jobs",
    "let",
    "local",
    "logout",
    "mapfile",
    "nocorrect",
    "noglob",
    "not",
    "or",
    "popd",
    "pushd",
    "read",
    "readarray",
    "readonly",
    "repeat",
    "return",
    "select",
    "set",
    "setopt",
    "shift",
    "shopt",
    "source",
    "switch",
    "suspend",
    "test",
    "then",
    "time",
    "times",
    "trap",
    "try",
    "true",
    "type",
    "typeset",
    "ulimit",
    "umask",
    "unalias",
    "until",
    "unset",
    "unsetopt",
    "wait",
    "while",
];

/// Unlike setup builtins, these make later segments control flow or
/// unreachable, so a later program does not name the command.
const TERMINAL_PROGRAMS: &[&str] = &[
    "and", "begin", "break", "case", "catch", "continue", "coproc", "do", "done", "elif", "else",
    "end", "esac", "eval", "exec", "exit", "false", "fi", "finally", "for", "foreach", "function",
    "if", "in", "not", "or", "repeat", "return", "select", "switch", "then", "try", "until",
    "while",
];

fn wrapper_options_with_value(wrapper: Wrapper) -> &'static [&'static str] {
    if wrapper == Wrapper::Env {
        &["-C", "--chdir", "-S", "--split-string", "-u", "--unset"]
    } else {
        &[
            "-C",
            "--close-from",
            "-D",
            "--chdir",
            "-g",
            "--group",
            "-u",
            "--user",
        ]
    }
}

fn wrapper_flags(wrapper: Wrapper) -> &'static [&'static str] {
    if wrapper == Wrapper::Env {
        &[
            "-0",
            "--null",
            "-i",
            "--ignore-environment",
            "--debug",
            "-v",
        ]
    } else {
        &[
            "-A",
            "--askpass",
            "-b",
            "--background",
            "-E",
            "-H",
            "-i",
            "-n",
            "-S",
        ]
    }
}

fn regex(pattern: &str) -> Regex {
    Regex::new(pattern).expect("a valid pattern")
}

macro_rules! pattern {
    ($name:ident, $pattern:expr) => {
        static $name: LazyLock<Regex> = LazyLock::new(|| regex($pattern));
    };
}

fn has(names: &[&str], name: &str) -> bool {
    names.contains(&name)
}

/// The character at `index`, or NUL past either end.
fn at(chars: &[char], index: usize) -> char {
    chars.get(index).copied().unwrap_or('\0')
}

fn before(chars: &[char], index: usize) -> char {
    if index == 0 { '\0' } else { chars[index - 1] }
}

fn sub(chars: &[char], start: usize, end: usize) -> String {
    let end = end.min(chars.len());
    if start >= end {
        return String::new();
    }
    chars[start..end].iter().collect()
}

fn token(tokens: &[String], index: usize) -> &str {
    tokens.get(index).map_or("", String::as_str)
}

fn first_char(text: &str) -> char {
    text.chars().next().unwrap_or('\0')
}

/// The last path segment, `/` or `\`.
fn base_name(token: &str) -> &str {
    token.rsplit(['/', '\\']).next().unwrap_or("")
}

fn tokenize(command: &str) -> Option<Vec<String>> {
    pattern!(WINDOWS_PATH, r"^(?:[A-Za-z]:|\.{1,2})(?:\\[^\s]*)?$");
    let input: Vec<char> = command.trim().chars().collect();
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut quote: Option<char> = None;
    let mut escaping = false;
    let mut in_backticks = false;
    let mut substitution_depth = 0;
    let mut parameter_depth = 0;
    let mut started = false;
    let mut skip = 0;

    for (index, &character) in input.iter().enumerate() {
        if skip > 0 {
            skip -= 1;
            continue;
        }
        if escaping {
            current.push(character);
            escaping = false;
            started = true;
            continue;
        }
        if character == '\\' && quote != Some('\'') {
            let next = at(&input, index + 1);
            let windows_path = quote.is_none() && WINDOWS_PATH.is_match(&current);
            if (quote == Some('"') || windows_path)
                && next != '\0'
                && !matches!(next, '"' | '\\' | '$' | '`' | '\n')
            {
                current.push(character);
                started = true;
                continue;
            }
            escaping = true;
            started = true;
            continue;
        }
        if in_backticks {
            current.push(character);
            if character == '`' {
                in_backticks = false;
            }
            started = true;
            continue;
        }
        if let Some(open) = quote {
            if character == open {
                quote = None;
            } else {
                current.push(character);
            }
            started = true;
            continue;
        }
        let was_started = started;
        started = true;
        match character {
            '`' => {
                current.push(character);
                in_backticks = true;
            }
            '$' if at(&input, index + 1) == '{' => {
                current.push_str("${");
                parameter_depth += 1;
                skip = 1;
            }
            '{' if parameter_depth > 0 => {
                current.push(character);
                parameter_depth += 1;
            }
            '}' if parameter_depth > 0 => {
                current.push(character);
                parameter_depth -= 1;
            }
            '$' if at(&input, index + 1) == '(' => {
                current.push_str("$(");
                substitution_depth += 1;
                skip = 1;
            }
            '(' => {
                current.push(character);
                substitution_depth += 1;
            }
            ')' if substitution_depth > 0 => {
                current.push(character);
                substitution_depth -= 1;
            }
            '"' | '\'' => quote = Some(character),
            c if c.is_whitespace() => {
                if substitution_depth > 0 || parameter_depth > 0 {
                    current.push(character);
                } else {
                    if was_started {
                        tokens.push(std::mem::take(&mut current));
                    }
                    started = false;
                }
            }
            _ => current.push(character),
        }
    }

    if quote.is_some() || escaping || in_backticks || substitution_depth > 0 || parameter_depth > 0
    {
        return None;
    }
    if started {
        tokens.push(current);
    }
    Some(tokens)
}

struct Split {
    first: String,
    /// Empty when the command is one segment.
    rest: String,
    separator: String,
}

struct Heredoc {
    delimiter: String,
    strip_tabs: bool,
}

#[derive(Clone, Copy)]
struct Range {
    start: usize,
    end: usize,
}

fn without_comments(command: &[char], end: usize, comments: &[Range]) -> String {
    let mut result = String::new();
    let mut cursor = 0;
    for comment in comments {
        if comment.start >= end {
            break;
        }
        result += &sub(command, cursor, comment.start);
        cursor = comment.end.min(end);
    }
    result + &sub(command, cursor, end)
}

fn read_heredoc_delimiter(
    command: &[char],
    start: usize,
    strip_tabs: bool,
) -> Option<(Heredoc, usize)> {
    let mut index = start;
    while matches!(at(command, index), ' ' | '\t') {
        index += 1;
    }
    let mut delimiter = String::new();
    let mut quote: Option<char> = None;
    let mut escaping = false;
    while index < command.len() {
        let character = command[index];
        index += 1;
        if escaping {
            delimiter.push(character);
            escaping = false;
            continue;
        }
        if character == '\\' && quote != Some('\'') {
            escaping = true;
            continue;
        }
        if let Some(open) = quote {
            if character == open {
                quote = None;
            } else {
                delimiter.push(character);
            }
            continue;
        }
        if character == '"' || character == '\'' {
            quote = Some(character);
            continue;
        }
        if character.is_whitespace() || ";&|<>()".contains(character) {
            index -= 1;
            break;
        }
        delimiter.push(character);
    }
    if delimiter.is_empty() || quote.is_some() || escaping {
        return None;
    }
    Some((
        Heredoc {
            delimiter,
            strip_tabs,
        },
        index,
    ))
}

/// What follows the heredoc bodies starting at `start`; empty when nothing
/// does, None when a body is not closed.
fn after_heredocs(command: &[char], start: usize, heredocs: &[Heredoc]) -> Option<String> {
    let mut cursor = start;
    for heredoc in heredocs {
        let mut found = false;
        while cursor <= command.len() {
            let newline = command
                .get(cursor..)
                .and_then(|rest| rest.iter().position(|&c| c == '\n'))
                .map(|offset| cursor + offset);
            let line_end = newline.unwrap_or(command.len());
            let mut line = sub(command, cursor, line_end);
            if line.ends_with('\r') {
                line.pop();
            }
            if heredoc.strip_tabs {
                line = line.trim_start_matches('\t').to_owned();
            }
            cursor = newline.map_or(command.len(), |n| n + 1);
            if line == heredoc.delimiter {
                found = true;
                break;
            }
            if newline.is_none() {
                break;
            }
        }
        if !found {
            return None;
        }
    }
    Some(sub(command, cursor, command.len()).trim().to_owned())
}

fn split_first(command: &str) -> Split {
    let c: Vec<char> = command.chars().collect();
    let mut quote: Option<char> = None;
    let mut here_string_quote: Option<char> = None;
    let mut escaping = false;
    let mut in_backticks = false;
    let mut in_comment = false;
    let mut substitution_depth = 0;
    let mut parameter_depth = 0;
    let mut heredocs: Vec<Heredoc> = Vec::new();
    let mut comments: Vec<Range> = Vec::new();
    let mut comment_start = 0;
    let mut separator_before_heredocs: Option<Range> = None;
    let mut index = 0;

    while index < c.len() {
        let character = c[index];
        let this = index;
        index += 1;
        if let Some(open) = here_string_quote {
            if character == open && at(&c, this + 1) == '@' && (this == 0 || c[this - 1] == '\n') {
                here_string_quote = None;
                index += 1;
            }
            continue;
        }
        if in_comment {
            if character != '\n' {
                continue;
            }
            in_comment = false;
            comments.push(Range {
                start: comment_start,
                end: this,
            });
        }
        if escaping {
            escaping = false;
            continue;
        }
        if character == '\\' && quote != Some('\'') {
            escaping = true;
            continue;
        }
        if in_backticks {
            if character == '`' {
                in_backticks = false;
            }
            continue;
        }
        if let Some(open) = quote {
            if character == open {
                quote = None;
            }
            continue;
        }
        let next = at(&c, this + 1);
        if character == '@'
            && (next == '"' || next == '\'')
            && (at(&c, this + 2) == '\n' || (at(&c, this + 2) == '\r' && at(&c, this + 3) == '\n'))
        {
            here_string_quote = Some(next);
            index += 1;
            continue;
        }
        if character == '"' || character == '\'' {
            quote = Some(character);
            continue;
        }
        if character == '`' {
            in_backticks = true;
            continue;
        }
        if character == '#'
            && (this == 0 || c[this - 1].is_whitespace() || ";&|(".contains(c[this - 1]))
        {
            in_comment = true;
            comment_start = this;
            continue;
        }
        if character == '$' && next == '{' {
            parameter_depth += 1;
            index += 1;
            continue;
        }
        if character == '{' && parameter_depth > 0 {
            parameter_depth += 1;
            continue;
        }
        if character == '}' && parameter_depth > 0 {
            parameter_depth -= 1;
            continue;
        }
        if character == '(' {
            substitution_depth += 1;
            continue;
        }
        if character == ')' && substitution_depth > 0 {
            substitution_depth -= 1;
            continue;
        }
        if substitution_depth > 0 || parameter_depth > 0 {
            continue;
        }

        if character == '<' && next == '<' && at(&c, this + 2) != '<' {
            let strip_tabs = at(&c, this + 2) == '-';
            let Some((heredoc, end)) =
                read_heredoc_delimiter(&c, this + if strip_tabs { 3 } else { 2 }, strip_tabs)
            else {
                return Split {
                    first: command.trim().to_owned(),
                    rest: String::new(),
                    separator: String::new(),
                };
            };
            heredocs.push(heredoc);
            index = end;
            continue;
        }

        let is_double =
            (character == '&' && next == '&') || (character == '|' && (next == '|' || next == '&'));
        let is_redirection =
            character == '&' && (before(&c, this) == '>' || before(&c, this) == '<' || next == '>');
        if (!is_double && !";&|\n".contains(character)) || is_redirection {
            continue;
        }

        if character == '\n' && !heredocs.is_empty() {
            let separator = separator_before_heredocs;
            let first = without_comments(&c, separator.map_or(this, |s| s.start), &comments)
                .trim_start()
                .to_owned();
            let between =
                separator.map_or_else(String::new, |s| sub(&c, s.end, this).trim().to_owned());
            let following = after_heredocs(&c, this + 1, &heredocs);
            let mut parts = Vec::new();
            if !between.is_empty() {
                parts.push(between);
            }
            if let Some(following) = following.filter(|f| !f.is_empty()) {
                parts.push(following);
            }
            return Split {
                first,
                rest: parts.join("\n"),
                separator: separator.map_or_else(|| "\n".to_owned(), |s| sub(&c, s.start, s.end)),
            };
        }
        if !heredocs.is_empty() {
            if separator_before_heredocs.is_none() {
                separator_before_heredocs = Some(Range {
                    start: this,
                    end: this + if is_double { 2 } else { 1 },
                });
            }
            if is_double {
                index += 1;
            }
            continue;
        }

        let first = without_comments(&c, this, &comments)
            .trim_start()
            .to_owned();
        let mut next_index = this + if is_double { 2 } else { 1 };
        while at(&c, next_index).is_whitespace() {
            next_index += 1;
        }
        return Split {
            first,
            rest: sub(&c, next_index, c.len()).trim().to_owned(),
            separator: if is_double {
                sub(&c, this, this + 2)
            } else {
                character.to_string()
            },
        };
    }

    if in_comment {
        comments.push(Range {
            start: comment_start,
            end: c.len(),
        });
    }
    Split {
        first: without_comments(&c, c.len(), &comments).trim().to_owned(),
        rest: String::new(),
        separator: String::new(),
    }
}

fn without_leading_comments(command: &str) -> Option<String> {
    let mut remaining = command.trim_start();
    while remaining.starts_with('#') {
        let newline = remaining.find('\n')?;
        remaining = remaining[newline + 1..].trim_start();
    }
    if remaining.is_empty() {
        return None;
    }
    Some(remaining.to_owned())
}

fn without_line_continuations(command: &str) -> String {
    let c: Vec<char> = command.chars().collect();
    let mut normalized = String::new();
    let mut quote: Option<char> = None;
    let mut escaping = false;
    let mut index = 0;
    while index < c.len() {
        let character = c[index];
        index += 1;
        if escaping {
            normalized.push(character);
            escaping = false;
            continue;
        }
        if character == '\\' && quote != Some('\'') {
            if at(&c, index) == '\n' {
                index += 1;
                continue;
            }
            if at(&c, index) == '\r' && at(&c, index + 1) == '\n' {
                index += 2;
                continue;
            }
            normalized.push(character);
            escaping = true;
            continue;
        }
        match quote {
            Some(open) if character == open => quote = None,
            None if character == '"' || character == '\'' => quote = Some(character),
            _ => {}
        }
        normalized.push(character);
    }
    normalized
}

/// The index after a redirection at `index` and its target; past the end
/// when the target is missing.
fn after_redirection(tokens: &[String], index: usize) -> Option<usize> {
    pattern!(PROCESS_SUBSTITUTION, r"^[<>]\(");
    pattern!(
        REDIRECTION,
        r"(?s)^(?:(?:(?:[0-9]+|\*|\{[A-Za-z_][A-Za-z0-9_]*\})?(?:<<<|<<-|<<|<>|>>|>\||<&|>&|<|>))|&>>|&>)(.*)$"
    );
    let token = tokens.get(index)?;
    if token.is_empty() || PROCESS_SUBSTITUTION.is_match(token) {
        return None;
    }
    let found = REDIRECTION.captures(token)?;
    if !found[1].is_empty() {
        return Some(index + 1);
    }
    Some(if index + 1 >= tokens.len() {
        tokens.len() + 1
    } else {
        index + 2
    })
}

fn serialize(tokens: &[String]) -> String {
    tokens
        .iter()
        .map(|token| format!("'{}'", token.replace('\'', r"'\''")))
        .collect::<Vec<_>>()
        .join(" ")
}

fn is_assignment(token: &str) -> bool {
    pattern!(ASSIGNMENT, r"^[A-Za-z_][A-Za-z0-9_]*\+?=");
    ASSIGNMENT.is_match(token)
}

fn transparent_wrapper_index(wrapper: &str, tokens: &[String], index: usize) -> Option<usize> {
    pattern!(SCRIPT_OPTION, r"^-[adkpqr]+$");
    pattern!(ARCHITECTURE, r"^-(?:arm64|arm64e|i386|x86_64)$");
    pattern!(DURATION, r"^(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)[smhd]?$");
    let exists = |i: usize| i < tokens.len();
    match wrapper {
        "bundle" => (token(tokens, index + 1) == "exec" && exists(index + 2)).then_some(index + 2),
        "nohup" => {
            let mut target = index + 1;
            if token(tokens, target) == "--" {
                target += 1;
            }
            let named = token(tokens, target);
            (exists(target) && !named.is_empty() && !named.starts_with('-')).then_some(target)
        }
        // BSD `script` takes an output file before the optional command.
        "script" => (SCRIPT_OPTION.is_match(token(tokens, index + 1)) && exists(index + 3))
            .then_some(index + 3),
        "arch" => {
            if ARCHITECTURE.is_match(token(tokens, index + 1)) {
                return exists(index + 2).then_some(index + 2);
            }
            (token(tokens, index + 1) == "-arch" && exists(index + 3)).then_some(index + 3)
        }
        "timeout" | "gtimeout" => {
            (DURATION.is_match(token(tokens, index + 1)) && exists(index + 2)).then_some(index + 2)
        }
        _ => None,
    }
}

fn static_program_name(value: &str) -> String {
    pattern!(SCHEME, r"^[A-Za-z][A-Za-z0-9+.-]*:");
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    // A URL's scheme, unless a path follows the colon (`C:\`, `c:/`).
    if let Some(scheme) = SCHEME.find(trimmed)
        && !matches!(trimmed[scheme.end()..].chars().next(), Some('\\' | '/'))
    {
        return String::new();
    }
    let program = base_name(trimmed);
    let spaced = program.chars().any(char::is_whitespace);
    let separated = trimmed.contains(['\\', '/']);
    if program.is_empty()
        || (spaced && !separated)
        || NON_PROGRAM_PREFIX.contains(first_char(program))
        || NON_PROGRAM_SUFFIX.contains(program.chars().last().unwrap_or('\0'))
    {
        return String::new();
    }
    program.to_owned()
}

fn leading_power_shell_literal(command: &str) -> String {
    let input: Vec<char> = command.trim_start().chars().collect();
    let quote = at(&input, 0);
    if quote != '"' && quote != '\'' {
        let word: String = input.iter().take_while(|c| !c.is_whitespace()).collect();
        return static_program_name(&word);
    }
    let mut value = String::new();
    let mut index = 1;
    while index < input.len() {
        let character = input[index];
        if character == '`' && index + 1 < input.len() {
            value.push(input[index + 1]);
            index += 2;
            continue;
        }
        if character == quote {
            if quote == '\'' && at(&input, index + 1) == '\'' {
                value.push('\'');
                index += 2;
                continue;
            }
            return static_program_name(&value);
        }
        value.push(character);
        index += 1;
    }
    String::new()
}

/// `& 'tool.exe' args`: None when the command is not a call.
fn call_operator_program(command: &str) -> Option<String> {
    pattern!(CALL, r"(?s)^\s*&\s+(.*)$");
    let found = CALL.captures(command)?;
    Some(leading_power_shell_literal(&found[1]))
}

/// None when `command` is not a PowerShell assignment.
fn power_shell_assignment_program(
    command: &str,
    depth: i32,
    rest: &str,
    segments_remaining: i32,
) -> Option<String> {
    pattern!(
        ASSIGNMENT,
        r"(?is)^\s*\$(?:(env|global|local|script):)?[A-Za-z_][A-Za-z0-9_]*\s*=\s*(.*)$"
    );
    pattern!(COLLECTION, r"(?i)^(?:\[ordered\]\s*)?@\s*[{(]");
    pattern!(DIRECT, r"^(?:@?\(\s*)?([A-Za-z][A-Za-z0-9_.-]*)\b");
    let found = ASSIGNMENT.captures(command)?;
    let next = || {
        if rest.is_empty() {
            String::new()
        } else {
            program_name(rest, depth, Context::Shell, segments_remaining - 1)
        }
    };
    // Environment assignments are setup; their value is not a command.
    if found
        .get(1)
        .is_some_and(|scope| scope.as_str().eq_ignore_ascii_case("env"))
    {
        return Some(next());
    }
    let value = found[2].trim();
    // The splitter does not balance PowerShell arrays or hashtables.
    if COLLECTION.is_match(value) {
        return Some(String::new());
    }
    if let Some(called) = call_operator_program(value) {
        return Some(called);
    }
    let direct = DIRECT
        .captures(value)
        .and_then(|m| m.get(1))
        .map_or("", |m| m.as_str());
    if !direct.is_empty() && !has(NON_DESCRIPTIVE_PROGRAMS, &direct.to_lowercase()) {
        let parsed = program_name(value, depth + 1, Context::Shell, segments_remaining);
        return Some(if parsed.is_empty() {
            direct.to_owned()
        } else {
            parsed
        });
    }
    Some(next())
}

/// None when no option of `shell` carries a command.
fn windows_shell_payload(
    shell: &str,
    tokens: &[String],
    start: usize,
    depth: i32,
    split: &Split,
    segments_remaining: i32,
) -> Option<String> {
    let payload = |index: usize| {
        let script = token(tokens, index);
        if script.is_empty() {
            return String::new();
        }
        let command = if !split.rest.is_empty() && !split.separator.is_empty() {
            format!("{script} {} {}", split.separator, split.rest)
        } else {
            script.to_owned()
        };
        program_name(&command, depth + 1, Context::Shell, segments_remaining)
    };
    if shell == "cmd" || shell == "cmd.exe" {
        return (start..tokens.len())
            .find(|&index| matches!(tokens[index].to_lowercase().as_str(), "/c" | "/k"))
            .map(|index| payload(index + 1));
    }
    let mut index = start;
    while index < tokens.len() {
        let option = tokens[index].to_lowercase();
        match option.as_str() {
            "-command" | "-c" => return Some(payload(index + 1)),
            "-file" | "-f" => return Some(static_program_name(token(tokens, index + 1))),
            "-encodedcommand" | "-enc" | "-e" => return Some(String::new()),
            _ => {}
        }
        if has(POWER_SHELL_OPTIONS_WITH_VALUE, &option) {
            index += 2;
            continue;
        }
        if has(POWER_SHELL_FLAGS, &option) {
            index += 1;
            continue;
        }
        if !option.starts_with('-') {
            return Some(static_program_name(&tokens[index]));
        }
        index += 1;
    }
    None
}

fn start_process_program(tokens: &[String], start: usize) -> String {
    let mut index = start;
    while index < tokens.len() {
        let token_ = &tokens[index];
        let option = token_.to_lowercase();
        if option == "-filepath" {
            return static_program_name(token(tokens, index + 1));
        }
        if has(START_PROCESS_FLAGS, &option) {
            index += 1;
            continue;
        }
        if has(START_PROCESS_OPTIONS_WITH_VALUE, &option) {
            if index + 1 >= tokens.len() {
                return String::new();
            }
            index += 2;
            continue;
        }
        if token_.starts_with('-') {
            return String::new();
        }
        return static_program_name(token_);
    }
    String::new()
}

/// `NAME=value`: the program a literal value names (empty when it names
/// none), None when the token is not an assignment.
fn literal_assignment(token: &str) -> Option<(String, String)> {
    pattern!(ASSIGNMENT, r"(?s)^([A-Za-z_][A-Za-z0-9_]*)=(.*)$");
    let found = ASSIGNMENT.captures(token)?;
    let name = found[1].to_owned();
    let mut value = found[2].trim().to_owned();
    if value.is_empty() || value.contains(['$', '`']) {
        return Some((name, String::new()));
    }
    if value.starts_with('(') && value.ends_with(')') && value.len() >= 2 {
        let inner = &value[1..value.len() - 1];
        value = tokenize(inner)
            .and_then(|array| array.into_iter().next())
            .unwrap_or_default();
    } else if value.chars().any(char::is_whitespace) && !value.contains(['\\', '/']) {
        return Some((name, String::new()));
    }
    let program = static_program_name(&value);
    Some((name, program))
}

fn referenced_alias(token: &str) -> String {
    pattern!(
        REFERENCE,
        r"^\$(?:([A-Za-z_][A-Za-z0-9_]*)|\{([A-Za-z_][A-Za-z0-9_]*)(?:\[@\])?\})$"
    );
    REFERENCE
        .captures(token)
        .and_then(|m| m.get(1).or_else(|| m.get(2)))
        .map_or_else(String::new, |m| m.as_str().to_owned())
}

/// Only literal aliases an earlier top-level segment declared, such as
/// `SSH=(ssh ...)` or `TOOL=/path/to/tool`; no expansion, no general state.
fn literal_alias_program(command: &str) -> String {
    let mut aliases: HashMap<String, String> = HashMap::new();
    let mut remaining = command.to_owned();
    let mut control_flow_depth: i32 = 0;
    let mut segment = 0;
    while !remaining.is_empty() && segment < 64 {
        segment += 1;
        let Some(uncommented) = without_leading_comments(&remaining) else {
            return String::new();
        };
        let split = split_first(&uncommented);
        let Some(tokens) = tokenize(&without_line_continuations(&split.first)) else {
            return String::new();
        };
        let leading = token(&tokens, 0);
        let mut command_index = usize::from(leading == "do" || leading == "then");
        while command_index < tokens.len() {
            if let Some(after) = after_redirection(&tokens, command_index)
                && after <= tokens.len()
            {
                command_index = after;
                continue;
            }
            if is_assignment(token(&tokens, command_index)) {
                command_index += 1;
                continue;
            }
            break;
        }
        let alias = referenced_alias(token(&tokens, command_index));
        if let Some(program) = aliases
            .get(&alias)
            .filter(|p| !alias.is_empty() && !p.is_empty())
        {
            return program.clone();
        }

        if matches!(leading, "fi" | "done" | "esac") {
            control_flow_depth = (control_flow_depth - 1).max(0);
        }
        if matches!(
            leading,
            "if" | "for" | "while" | "until" | "select" | "case"
        ) {
            control_flow_depth += 1;
        }
        if control_flow_depth == 0 && leading == "unset" {
            for name in &tokens[1..] {
                aliases.remove(name);
            }
        }
        let assignment_start = usize::from(leading == "export");
        let assignments: Option<Vec<(String, String)>> = (tokens.len() > assignment_start)
            .then(|| {
                tokens[assignment_start..]
                    .iter()
                    .map(|t| literal_assignment(t))
                    .collect()
            })
            .flatten();
        if control_flow_depth == 0
            && let Some(assignments) = assignments
        {
            for (name, program) in assignments {
                if program.is_empty() {
                    aliases.remove(&name);
                } else {
                    aliases.insert(name, program);
                }
            }
        }
        remaining = split.rest;
    }
    String::new()
}

fn wrapped_shell_program(
    wrapper: &str,
    tokens: &[String],
    start: usize,
    depth: i32,
    rest: &str,
    segments_remaining: i32,
) -> String {
    pattern!(EXEC_NAME, r"^-a.+");
    pattern!(EXEC_FLAGS, r"^-[cl]+$");
    let mut index = start;
    match wrapper {
        "command" => {
            while index < tokens.len() {
                let option = tokens[index].as_str();
                if option == "--" {
                    index += 1;
                    break;
                }
                if !option.starts_with('-') || option == "-" {
                    break;
                }
                if option != "-p" {
                    return String::new();
                }
                index += 1;
            }
        }
        "builtin" => {
            if token(tokens, index) == "--" {
                index += 1;
            } else if token(tokens, index).starts_with('-') {
                return String::new();
            }
        }
        "exec" => {
            while index < tokens.len() {
                let option = tokens[index].as_str();
                if option == "--" {
                    index += 1;
                    break;
                }
                if option == "-a" {
                    if index + 1 >= tokens.len() {
                        return String::new();
                    }
                    index += 2;
                    continue;
                }
                if EXEC_NAME.is_match(option) || EXEC_FLAGS.is_match(option) {
                    index += 1;
                    continue;
                }
                if option.starts_with('-') && option != "-" {
                    return String::new();
                }
                break;
            }
        }
        _ => {}
    }

    let wrapped = tokens.get(index..).unwrap_or_default();
    if wrapped.is_empty() {
        return String::new();
    }
    let mut target_index = 0;
    while target_index < wrapped.len() {
        match after_redirection(wrapped, target_index) {
            Some(after) if after <= wrapped.len() => target_index = after,
            _ => break,
        }
    }
    let target = token(wrapped, target_index);
    if !target.is_empty() && is_assignment(target) {
        return String::new();
    }
    let context = if wrapper == "exec" {
        Context::Exec
    } else {
        Context::Shell
    };
    let program = program_name(&serialize(wrapped), depth + 1, context, segments_remaining);
    if !program.is_empty() {
        return program;
    }
    if wrapper != "exec"
        && !target.is_empty()
        && target == target.to_lowercase()
        && has(NON_DESCRIPTIVE_PROGRAMS, target)
        && !has(TERMINAL_PROGRAMS, target)
        && !rest.is_empty()
    {
        return program_name(rest, depth, Context::Shell, segments_remaining - 1);
    }
    String::new()
}

/// The index of a shell's `-c` script among `tokens` after the shell.
fn shell_script_index(tokens: &[String], start: usize) -> Option<usize> {
    pattern!(COMMAND_FLAG, r"^-[a-zA-Z]*c[a-zA-Z]*$");
    let mut index = start;
    while index < tokens.len() {
        let option = tokens[index].as_str();
        if option == "--" || !option.starts_with('-') {
            return None;
        }
        if has(SHELL_OPTIONS_WITH_VALUE, option) {
            index += 2;
            continue;
        }
        if option == "--command" || COMMAND_FLAG.is_match(option) {
            return Some(index + 1);
        }
        index += 1;
    }
    None
}

fn parse_program_name(
    command: &str,
    depth: i32,
    context: Context,
    segments_remaining: i32,
) -> String {
    pattern!(
        BLOCK,
        r"(?i)^(?:catch|finally|for|foreach|function|if|param|switch|try|while)\s*[{(]"
    );
    pattern!(FUNCTION, r"^[A-Za-z_][A-Za-z0-9_]*\s*\(\s*\)\s*\{");
    pattern!(HERE_STRING, r#"^@["'](?:\r?\n)"#);
    pattern!(
        WINDOWS_PATH,
        r"(?i)^\s*((?:\.{1,2}|%[A-Za-z_][A-Za-z0-9_]*%|\$env:[A-Za-z_][A-Za-z0-9_]*)\\\S+)"
    );
    pattern!(QUOTED_SYNTAX, r"[\s()=]");
    pattern!(SHORT_OPTIONS, r"^-[A-Za-z].+");
    pattern!(EXE_SUFFIX, r"(?i)\.exe$");
    pattern!(FUNCTION_TOKEN, r"^[A-Za-z_][A-Za-z0-9_]*\(\)\{$");

    if depth >= 8 || segments_remaining <= 0 {
        return String::new();
    }
    let Some(uncommented) = without_leading_comments(command) else {
        return String::new();
    };
    if BLOCK.is_match(&uncommented) || FUNCTION.is_match(&uncommented) {
        return String::new();
    }
    // `&&` and `||` inside `[[ ... ]]` are not separators; stay conservative.
    if uncommented.starts_with("[[") {
        return String::new();
    }
    let split = split_first(&uncommented);
    let next = |next_context: Context| {
        if split.rest.is_empty() {
            String::new()
        } else {
            program_name(&split.rest, depth, next_context, segments_remaining - 1)
        }
    };
    if HERE_STRING.is_match(split.first.trim_start()) {
        return next(Context::Shell);
    }
    if let Some(program) =
        power_shell_assignment_program(&split.first, depth, &split.rest, segments_remaining)
    {
        return program;
    }
    if let Some(path) = WINDOWS_PATH.captures(&split.first).and_then(|m| m.get(1)) {
        return static_program_name(path.as_str());
    }
    let Some(tokens) = tokenize(&without_line_continuations(&split.first)) else {
        return String::new();
    };
    let first_character = first_char(split.first.trim_start());
    if tokens.len() == 1
        && (first_character == '"' || first_character == '\'')
        && QUOTED_SYNTAX.is_match(&tokens[0])
        && !tokens[0].contains(['\\', '/'])
    {
        return next(context);
    }

    let mut index = 0;
    let mut wrapper = Wrapper::None;
    let mut execution = context;
    let mut saw_assignment = false;
    let mut saw_redirection = false;

    while index < tokens.len() {
        let token_ = tokens[index].as_str();
        if token_.is_empty() {
            return String::new();
        }
        if let Some(after) = after_redirection(&tokens, index) {
            if after > tokens.len() {
                return String::new();
            }
            saw_redirection = true;
            index = after;
            continue;
        }
        if is_assignment(token_) {
            saw_assignment = true;
            index += 1;
            continue;
        }
        if execution == Context::Shell && token_ == ":" {
            return next(execution);
        }
        if NON_PROGRAM_PREFIX.contains(first_char(token_))
            && !(token_.starts_with('$') && token_.contains('/'))
        {
            return if execution == Context::Shell && token_.starts_with('[') {
                next(execution)
            } else {
                String::new()
            };
        }
        let program = base_name(token_);
        let unqualified = token_ == program;
        if program == "env" || program == "sudo" {
            wrapper = if program == "env" {
                Wrapper::Env
            } else {
                Wrapper::Sudo
            };
            execution = Context::Exec;
            index += 1;
            continue;
        }
        if wrapper != Wrapper::None && token_ == "--" {
            wrapper = Wrapper::None;
            index += 1;
            continue;
        }
        if wrapper != Wrapper::None && token_.starts_with('-') {
            if wrapper == Wrapper::Env && (token_ == "-S" || token_ == "--split-string") {
                let script = token(&tokens, index + 1);
                return if script.is_empty() {
                    String::new()
                } else {
                    program_name(script, depth + 1, execution, segments_remaining)
                };
            }
            if wrapper == Wrapper::Env
                && let Some(script) = token_.strip_prefix("--split-string=")
            {
                return program_name(script, depth + 1, execution, segments_remaining);
            }
            if has(wrapper_options_with_value(wrapper), token_) {
                if index + 1 >= tokens.len() {
                    return String::new();
                }
                index += 2;
                continue;
            }
            if has(wrapper_flags(wrapper), token_) {
                index += 1;
                continue;
            }
            if token_.starts_with("--")
                && let Some(equals) = token_.find('=').filter(|&e| e > 2)
            {
                if !has(wrapper_options_with_value(wrapper), &token_[..equals]) {
                    return String::new();
                }
                index += 1;
                continue;
            }
            if SHORT_OPTIONS.is_match(token_) && !token_.starts_with("--") {
                let letters: Vec<char> = token_.chars().skip(1).collect();
                let mut consumes_next = false;
                for (i, letter) in letters.iter().enumerate() {
                    let option = format!("-{letter}");
                    if has(wrapper_options_with_value(wrapper), &option) {
                        consumes_next = i == letters.len() - 1;
                        break;
                    }
                    if !has(wrapper_flags(wrapper), &option) {
                        return String::new();
                    }
                }
                if consumes_next && index + 1 >= tokens.len() {
                    return String::new();
                }
                index += if consumes_next { 2 } else { 1 };
                continue;
            }
            return String::new();
        }
        if has(
            SHELL_PROGRAMS,
            &EXE_SUFFIX.replace(program, "").to_lowercase(),
        ) && let Some(script) = shell_script_index(&tokens, index + 1)
        {
            let script = token(&tokens, script);
            return if script.is_empty() {
                String::new()
            } else {
                program_name(script, depth + 1, Context::Shell, segments_remaining)
            };
        }
        let lower = program.to_lowercase();
        if has(WINDOWS_SHELL_PROGRAMS, &lower)
            && let Some(payload) = windows_shell_payload(
                &lower,
                &tokens,
                index + 1,
                depth,
                &split,
                segments_remaining,
            )
        {
            return payload;
        }
        if lower == "start-process" {
            let started = start_process_program(&tokens, index + 1);
            if !started.is_empty() {
                return started;
            }
        }
        if execution == Context::Shell && unqualified && has(SHELL_PRECOMMAND_MODIFIERS, program) {
            index += 1;
            if program == "time" && token(&tokens, index) == "-p" {
                index += 1;
            }
            if token(&tokens, index).starts_with('-') {
                return String::new();
            }
            continue;
        }
        if unqualified && let Some(target) = transparent_wrapper_index(program, &tokens, index) {
            let wrapped = program_name(
                &serialize(&tokens[target..]),
                depth + 1,
                Context::Exec,
                segments_remaining,
            );
            if !wrapped.is_empty() {
                return wrapped;
            }
        }
        if unqualified && has(SHELL_COMMAND_WRAPPERS, program) {
            return wrapped_shell_program(
                program,
                &tokens,
                index + 1,
                depth,
                &split.rest,
                segments_remaining,
            );
        }
        if (execution == Context::Shell
            || (wrapper == Wrapper::Sudo && has(SKIPPABLE_SUDO_PROBES, program)))
            && unqualified
            && has(NON_DESCRIPTIVE_PROGRAMS, program)
            && (!has(TERMINAL_PROGRAMS, program) || (program == "false" && split.separator != "&&"))
            && !split.rest.is_empty()
        {
            return next(Context::Shell);
        }
        if execution == Context::Shell
            && unqualified
            && has(POWER_SHELL_SETUP_PROGRAMS, &lower)
            && !split.rest.is_empty()
        {
            return next(Context::Shell);
        }
        if program.is_empty()
            || (unqualified && has(NON_DESCRIPTIVE_PROGRAMS, program))
            || NON_PROGRAM_PREFIX.contains(first_char(program))
            || NON_PROGRAM_SUFFIX.contains(program.chars().last().unwrap_or('\0'))
            || program.ends_with("()")
            || FUNCTION_TOKEN.is_match(program)
        {
            return String::new();
        }
        return program.to_owned();
    }

    if (saw_assignment || saw_redirection) && wrapper == Wrapper::None {
        return next(execution);
    }
    String::new()
}

fn program_name(command: &str, depth: i32, context: Context, segments_remaining: i32) -> String {
    if segments_remaining <= 0 {
        return String::new();
    }
    if let Some(called) = call_operator_program(command) {
        return called;
    }
    let parsed = parse_program_name(command, depth, context, segments_remaining);
    if !parsed.is_empty() || context != Context::Shell {
        return parsed;
    }
    literal_alias_program(command)
}

/// The program a shell command runs, for a live row's "Ran git": shell
/// `-c` wrappers, `env`/`sudo`, `timeout` and similar wrappers, Windows
/// shells and setup segments such as `cd dir &&` are looked through. Empty
/// when nothing names a program: a bare `cd`, control flow, an unbalanced
/// quote.
pub fn command_program_name(command: &str) -> String {
    program_name(command, 0, Context::Shell, MAX_COMMAND_SEGMENTS)
}

#[cfg(test)]
mod tests {
    use super::command_program_name as name;

    #[test]
    fn names_the_program_through_shells_and_setup() {
        for (command, program) in [
            ("/bin/zsh -lc 'git diff --check'", "git"),
            ("bash -lc \"zsh -c 'git status'\"", "git"),
            ("cd apps/web && vp test run", "vp"),
            ("export CI=1 && vp test run", "vp"),
            ("CI=1 env -u DEBUG sudo -u root vp test run", "vp"),
            ("timeout 10 pnpm test", "pnpm"),
            ("vp test && git status", "vp"),
            (
                "pwsh -NoProfile -Command \"Set-Location C:\\work; pnpm test\"",
                "pnpm",
            ),
            ("npm test", "npm"),
            ("TOOL=/usr/bin/rg; $TOOL foo", "rg"),
            ("cat <<EOF\nhello\nEOF\n", "cat"),
            ("# setup\ncargo build", "cargo"),
            ("& 'C:\\tools\\tool.exe' run", "tool.exe"),
            ("nohup -- node server.js", "node"),
        ] {
            assert_eq!(name(command), program, "{command}");
        }
    }

    #[test]
    fn names_no_program_when_none_runs() {
        for command in [
            "cd packages/client-runtime",
            "if test -f package.json; then vp test; fi",
            "export NODE_ENV=test",
            "zsh -lc 'git status",
            "",
            "[[ -f x && -f y ]]",
        ] {
            assert_eq!(name(command), "", "{command}");
        }
    }
}
