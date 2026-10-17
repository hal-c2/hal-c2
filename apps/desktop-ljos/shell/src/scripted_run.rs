//! Scripted runs, desktop-qt's ScriptedRun: `--action name[=json]` and
//! `--key <chord>` steps replayed in command-line order, 1.5 s apart, once
//! the MC's first snapshot is in; and `--screenshot <png>`, a picture taken
//! 1.5 s after the last one. PR evidence and smoke runs without a person at
//! the window.
//!
//! The command line is parsed into [`Step`]s in `main.rs` (the order the
//! options came in is the order they run in); [`play`] schedules them on the
//! engine's clock, so a picture taken on a virtual clock replays all of them
//! without waiting.
//!
//! A key chord is not pressed into the window: Ljós gives an application no
//! way to put a key event into the window's scene (the setup closure holds
//! the engine, not the scene). It goes where a window `Shortcut` would send
//! it, to [`Keymap::press`](crate::controllers::keybindings::Keymap::press)
//! with the keyboard in the chrome, so a chord that is a shell command runs
//! it and any other chord (a key for the focused control) does nothing, and
//! says so.

use std::time::Duration;

use ljos::prelude::Engine;

use crate::bridge::Bridge;
use crate::controllers::keybindings::{Focus, Keymap};
use crate::json::Json;

/// How far apart the steps run, and how long after the last one a picture
/// is taken.
pub const SPACING: Duration = Duration::from_millis(1500);

/// One thing a scripted run does.
#[derive(Clone, Debug, PartialEq)]
pub enum Step {
    /// A shell action, as `Shell.dispatch` sends it.
    Action { name: String, payload: Json },
    /// A key chord in the portable `QKeySequence` names (`Ctrl+1`).
    Key(String),
}

impl Step {
    /// `--action`'s value: the action's name, then its JSON payload after a
    /// `=` or a space (`rightPanel.toggle`, `theme.mode={"mode":"dark"}`,
    /// `theme.mode {"mode":"dark"}`). A payload that is not JSON is none;
    /// the second half says why, for the caller to tell.
    pub fn action(spec: &str) -> (Step, Option<String>) {
        let (name, payload) = match spec.find([' ', '=']) {
            Some(at) => (&spec[..at], spec[at + 1..].trim()),
            None => (spec, ""),
        };
        let (payload, note) = if payload.is_empty() {
            (Json::Null, None)
        } else {
            match serde_json::from_str(payload) {
                Ok(payload) => (payload, None),
                Err(e) => (
                    Json::Null,
                    Some(format!(
                        "--action {name}: the payload is not JSON ({e}), so none"
                    )),
                ),
            }
        };
        (
            Step::Action {
                name: name.to_owned(),
                payload,
            },
            note,
        )
    }

    /// What the log says of the step.
    fn describe(&self) -> String {
        match self {
            Step::Action { name, .. } => format!("scripted action {name}"),
            Step::Key(chord) => format!("scripted key {chord}"),
        }
    }
}

/// When each of `count` steps runs, after the run starts, and when a
/// picture is taken after them: the first step at 1.5 s, each next 1.5 s
/// later, the picture 1.5 s after the last (3 s with no steps).
pub fn timetable(count: usize) -> (Vec<Duration>, Duration) {
    let at = |n: usize| SPACING * (n as u32);
    let steps = (1..=count).map(at).collect();
    (steps, at(count + 2))
}

/// Schedules `steps` from now on `engine`'s clock; call it once the window
/// shows what they act on (the first snapshot is in, see
/// [`when_active`](crate::when_active)). Each one is logged as it runs.
pub fn play(engine: &Engine, steps: Vec<Step>) {
    let (delays, _) = timetable(steps.len());
    for (step, delay) in steps.into_iter().zip(delays) {
        engine.call_at(engine.now() + delay, move |engine| {
            eprintln!("[shell] {}", step.describe());
            run(engine, &step);
        });
    }
}

/// Runs one step now. False when it was a chord the shell does not take.
pub fn run(engine: &Engine, step: &Step) -> bool {
    match step {
        Step::Action { name, payload } => {
            Bridge::of(engine).dispatch(engine, name, payload.clone());
            true
        }
        Step::Key(chord) => press(engine, chord),
    }
}

/// Presses `chord` as a window shortcut: true when it ran a command.
fn press(engine: &Engine, chord: &str) -> bool {
    let sequence = match sequence(chord) {
        Ok(sequence) => sequence,
        Err(e) => {
            eprintln!("[shell] {e}: {chord}");
            return false;
        }
    };
    let ran = Keymap::of(engine).press(engine, &sequence, Focus::default());
    if !ran {
        eprintln!("[shell] no window shortcut for {chord}");
    }
    ran
}

/// The sequence the keymap registers for a portable `QKeySequence` chord
/// (`ctrl+shift+e` is `Ctrl+Shift+E`), or why it is not one chord.
pub fn sequence(chord: &str) -> Result<String, String> {
    let chord = chord.trim();
    // QKeySequence's chords are separated by ", ": more than one is not a
    // chord, and none is not either.
    if chord.is_empty() || chord.contains(", ") {
        return Err("not a single key chord".into());
    }
    // "Ctrl++" is Ctrl and the plus key.
    let (modifiers, key) = match chord.strip_suffix('+') {
        Some("") => ("", "+"),
        Some(head) => (
            head.strip_suffix('+')
                .ok_or("not a single key chord".to_owned())?,
            "+",
        ),
        None => match chord.rsplit_once('+') {
            Some((head, key)) => (head, key),
            None => ("", chord),
        },
    };
    let (mut ctrl, mut meta, mut alt, mut shift) = (false, false, false, false);
    for name in modifiers.split('+').filter(|m| !m.is_empty()) {
        match name.trim().to_ascii_lowercase().as_str() {
            "ctrl" | "control" => ctrl = true,
            "meta" => meta = true,
            "alt" => alt = true,
            "shift" => shift = true,
            other => return Err(format!("{other:?} is not a modifier")),
        }
    }
    let key = key_name(key.trim()).ok_or_else(|| format!("{key:?} is not a key"))?;
    // The order `keybindings::sequence` writes them in.
    let mut parts = Vec::new();
    for (held, name) in [
        (ctrl, "Ctrl"),
        (meta, "Meta"),
        (alt, "Alt"),
        (shift, "Shift"),
    ] {
        if held {
            parts.push(name);
        }
    }
    parts.push(&key);
    Ok(parts.join("+"))
}

/// The portable name of a key, as the keymap writes it.
fn key_name(key: &str) -> Option<String> {
    let lower = key.to_ascii_lowercase();
    let named = match lower.as_str() {
        "space" => "Space",
        "up" => "Up",
        "down" => "Down",
        "left" => "Left",
        "right" => "Right",
        "backspace" => "Backspace",
        "del" | "delete" => "Del",
        "ins" | "insert" => "Ins",
        "end" => "End",
        "home" => "Home",
        "esc" | "escape" => "Esc",
        "enter" | "return" => "Return",
        "pgup" | "pageup" => "PgUp",
        "pgdown" | "pagedown" => "PgDown",
        "tab" => "Tab",
        _ => "",
    };
    if !named.is_empty() {
        return Some(named.to_owned());
    }
    let function = lower
        .strip_prefix('f')
        .filter(|n| !n.starts_with('0'))
        .and_then(|n| n.parse::<u32>().ok())
        .filter(|n| (1..=24).contains(n));
    if let Some(n) = function {
        return Some(format!("F{n}"));
    }
    (key.chars().count() == 1).then(|| key.to_uppercase())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn action(spec: &str) -> Step {
        Step::action(spec).0
    }

    #[test]
    fn an_action_is_its_name_and_the_json_after_a_space_or_an_equals_sign() {
        let toggle = Step::Action {
            name: "rightPanel.toggle".into(),
            payload: Json::Null,
        };
        assert_eq!(action("rightPanel.toggle"), toggle);
        let dark = Step::Action {
            name: "theme.mode".into(),
            payload: json!({"mode": "dark", "note": "a = b c"}),
        };
        assert_eq!(
            action(r#"theme.mode={"mode": "dark", "note": "a = b c"}"#),
            dark
        );
        assert_eq!(
            action(r#"theme.mode {"mode": "dark", "note": "a = b c"}"#),
            dark
        );
    }

    #[test]
    fn a_payload_that_is_not_json_is_none_and_is_told() {
        let (step, note) = Step::action("theme.mode={mode:dark}");
        assert_eq!(
            step,
            Step::Action {
                name: "theme.mode".into(),
                payload: Json::Null
            }
        );
        assert!(note.is_some_and(|n| n.contains("--action theme.mode")));
        // Nothing after the name is nothing to tell.
        assert_eq!(Step::action("settings.open=").1, None);
        assert_eq!(Step::action("settings.open").1, None);
    }

    #[test]
    fn steps_run_one_and_a_half_seconds_apart_and_the_picture_follows_the_last() {
        let ms = |count| {
            let (steps, picture) = timetable(count);
            (
                steps.iter().map(Duration::as_millis).collect::<Vec<_>>(),
                picture.as_millis(),
            )
        };
        assert_eq!(ms(0), (vec![], 3000));
        assert_eq!(ms(1), (vec![1500], 4500));
        assert_eq!(ms(3), (vec![1500, 3000, 4500], 7500));
    }

    #[test]
    fn a_chord_is_the_sequence_the_keymap_registers() {
        let seq = |chord| sequence(chord).unwrap();
        assert_eq!(seq("Ctrl+1"), "Ctrl+1");
        assert_eq!(seq("ctrl+shift+e"), "Ctrl+Shift+E");
        assert_eq!(seq("Shift+Alt+Meta+Control+k"), "Ctrl+Meta+Alt+Shift+K");
        assert_eq!(seq("Ctrl+Shift+Return"), "Ctrl+Shift+Return");
        assert_eq!(seq("Ctrl+Enter"), "Ctrl+Return");
        assert_eq!(seq("Ctrl+Escape"), "Ctrl+Esc");
        assert_eq!(seq("Alt+PageDown"), "Alt+PgDown");
        assert_eq!(seq("Ctrl+f12"), "Ctrl+F12");
        assert_eq!(seq("Ctrl+["), "Ctrl+[");
        assert_eq!(seq("Ctrl+,"), "Ctrl+,");
        // The plus key, with and without a modifier.
        assert_eq!(seq("Ctrl++"), "Ctrl++");
        assert_eq!(seq("+"), "+");
        assert_eq!(seq("Escape"), "Esc");
    }

    #[test]
    fn what_is_not_one_chord_is_refused() {
        for chord in [
            "",
            "Ctrl+K, Ctrl+S",
            "Ctrl+",
            "Hyper+K",
            "Ctrl+F25",
            "Ctrl+Foo",
        ] {
            assert!(sequence(chord).is_err(), "{chord:?}");
        }
        assert_eq!(
            sequence("Ctrl+K, Ctrl+S").unwrap_err(),
            "not a single key chord"
        );
    }
}
