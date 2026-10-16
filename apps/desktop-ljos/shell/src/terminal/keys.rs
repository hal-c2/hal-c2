//! What the terminal sends a program for a key or a mouse report: xterm's
//! legacy encodings, as a pure function of Qt's key numbers.
//!
//! Not done: the kitty keyboard protocol, which libghostty's encoder speaks
//! and `vt100` does not track.

use ljos_quick::Modifiers;
use ljos_quick::keys::key;

/// xterm's modifier parameter: 1 plus shift 1, alt 2, control 4, meta 8.
fn modifier_param(m: Modifiers) -> u8 {
    1 + u8::from(m.contains(Modifiers::SHIFT))
        + 2 * u8::from(m.contains(Modifiers::ALT))
        + 4 * u8::from(m.contains(Modifiers::CONTROL))
        + 8 * u8::from(m.contains(Modifiers::META))
}

/// `CSI <letter>`, or `CSI 1;<m> <letter>` with modifiers; `SS3 <letter>`
/// for the application cursor mode without any.
fn cursor(letter: u8, m: Modifiers, application: bool) -> Vec<u8> {
    match (modifier_param(m), application) {
        (1, true) => vec![0x1b, b'O', letter],
        (1, false) => vec![0x1b, b'[', letter],
        (p, _) => format!("\x1b[1;{p}{}", letter as char).into_bytes(),
    }
}

/// `CSI <n> ~`, or `CSI <n>;<m> ~`.
fn tilde(n: u8, m: Modifiers) -> Vec<u8> {
    match modifier_param(m) {
        1 => format!("\x1b[{n}~").into_bytes(),
        p => format!("\x1b[{n};{p}~").into_bytes(),
    }
}

/// SS3 P..S for F1 to F4, `CSI 1;<m> P..S` with modifiers.
fn low_function(letter: u8, m: Modifiers) -> Vec<u8> {
    match modifier_param(m) {
        1 => vec![0x1b, b'O', letter],
        p => format!("\x1b[1;{p}{}", letter as char).into_bytes(),
    }
}

/// The control character for Ctrl plus `key`, if there is one.
fn control_byte(k: i32) -> Option<u8> {
    match k {
        key::A..=key::Z => Some((k as u8) & 0x1f),
        key::SPACE => Some(0),
        0x5b => Some(0x1b), // [
        0x5c => Some(0x1c), // \
        0x5d => Some(0x1d), // ]
        0x5e => Some(0x1e), // ^
        0x5f | key::MINUS => Some(0x1f),
        0x40 => Some(0), // @
        0x32 => Some(0), // 2
        0x36 => Some(0x1e),
        _ => None,
    }
}

/// The bytes for a key press, or none when it sends nothing (a bare
/// modifier, a shortcut). `application_cursor` is DECCKM.
pub fn encode_key(
    k: i32,
    modifiers: Modifiers,
    text: &str,
    application_cursor: bool,
) -> Option<Vec<u8>> {
    let m = modifiers - Modifiers::KEYPAD;
    let alt = m.contains(Modifiers::ALT);
    let esc = |mut bytes: Vec<u8>| {
        if alt {
            bytes.insert(0, 0x1b);
        }
        Some(bytes)
    };
    match k {
        key::RETURN | key::ENTER => return esc(vec![b'\r']),
        key::TAB => return esc(vec![b'\t']),
        key::BACKTAB => return Some(b"\x1b[Z".to_vec()),
        key::BACKSPACE => {
            let byte = if m.contains(Modifiers::CONTROL) {
                0x08
            } else {
                0x7f
            };
            return esc(vec![byte]);
        }
        key::ESCAPE => return esc(vec![0x1b]),
        key::UP => return Some(cursor(b'A', m, application_cursor)),
        key::DOWN => return Some(cursor(b'B', m, application_cursor)),
        key::RIGHT => return Some(cursor(b'C', m, application_cursor)),
        key::LEFT => return Some(cursor(b'D', m, application_cursor)),
        key::HOME => return Some(cursor(b'H', m, application_cursor)),
        key::END => return Some(cursor(b'F', m, application_cursor)),
        key::INSERT => return Some(tilde(2, m)),
        key::DELETE => return Some(tilde(3, m)),
        key::PAGE_UP => return Some(tilde(5, m)),
        key::PAGE_DOWN => return Some(tilde(6, m)),
        _ => {}
    }
    if (key::F1..=key::F1 + 3).contains(&k) {
        return Some(low_function(b'P' + (k - key::F1) as u8, m));
    }
    if (key::F1 + 4..=key::F1 + 11).contains(&k) {
        const CODES: [u8; 8] = [15, 17, 18, 19, 20, 21, 23, 24];
        return Some(tilde(CODES[(k - key::F1 - 4) as usize], m));
    }
    if m.contains(Modifiers::CONTROL)
        && !m.contains(Modifiers::META)
        && let Some(b) = control_byte(k)
    {
        return esc(vec![b]);
    }
    let first = text.chars().next()?;
    if first.is_control() {
        return None;
    }
    esc(text.as_bytes().to_vec())
}

/// How a program asked for mouse reports to be written.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MouseEncoding {
    Default,
    Utf8,
    Sgr,
}

/// What a report is about.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MouseAction {
    Press,
    Release,
    Motion,
}

/// A mouse report for `button` (0 left, 1 middle, 2 right, 3 none, 4 and 5
/// the wheel up and down) at the 0-based cell `(col, row)`.
pub fn encode_mouse(
    encoding: MouseEncoding,
    action: MouseAction,
    button: u8,
    modifiers: Modifiers,
    col: u16,
    row: u16,
) -> Vec<u8> {
    let mut code = match button {
        4 => 64,
        5 => 65,
        b => b.min(3),
    };
    if modifiers.contains(Modifiers::SHIFT) {
        code += 4;
    }
    if modifiers.contains(Modifiers::ALT) {
        code += 8;
    }
    if modifiers.contains(Modifiers::CONTROL) {
        code += 16;
    }
    if action == MouseAction::Motion {
        code += 32;
    }
    let (x, y) = (u32::from(col) + 1, u32::from(row) + 1);
    match encoding {
        MouseEncoding::Sgr => {
            let end = if action == MouseAction::Release {
                'm'
            } else {
                'M'
            };
            format!("\x1b[<{code};{x};{y}{end}").into_bytes()
        }
        MouseEncoding::Default | MouseEncoding::Utf8 => {
            // A release has no button in these encodings.
            let code = if action == MouseAction::Release {
                (code & !0b11) | 3
            } else {
                code
            };
            let mut out = b"\x1b[M".to_vec();
            for v in [u32::from(code) + 32, x + 32, y + 32] {
                if encoding == MouseEncoding::Utf8 {
                    let c = char::from_u32(v).unwrap_or(' ');
                    let mut buf = [0u8; 4];
                    out.extend_from_slice(c.encode_utf8(&mut buf).as_bytes());
                } else {
                    // One byte: a position past the 223rd cell cannot be
                    // said, so it is clamped to the last that can.
                    out.push(v.min(255) as u8);
                }
            }
            out
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NONE: Modifiers = Modifiers::empty();

    fn press(k: i32, m: Modifiers, text: &str) -> Option<String> {
        encode_key(k, m, text, false).map(|b| String::from_utf8_lossy(&b).into_owned())
    }

    #[test]
    fn plain_text_is_sent_as_typed() {
        assert_eq!(press(key::A, NONE, "a").as_deref(), Some("a"));
        assert_eq!(press(key::A, Modifiers::SHIFT, "A").as_deref(), Some("A"));
        assert_eq!(press(0xe9, NONE, "é").as_deref(), Some("é"));
    }

    #[test]
    fn control_letters_and_alt_prefixes() {
        assert_eq!(
            press(key::A + 2, Modifiers::CONTROL, "\u{3}").as_deref(),
            Some("\u{3}")
        );
        assert_eq!(
            press(key::A + 3, Modifiers::CONTROL, "").as_deref(),
            Some("\u{4}")
        );
        assert_eq!(
            press(key::A + 1, Modifiers::ALT, "b").as_deref(),
            Some("\u{1b}b")
        );
        assert_eq!(
            press(key::SPACE, Modifiers::CONTROL, " ").as_deref(),
            Some("\0")
        );
    }

    #[test]
    fn editing_keys() {
        assert_eq!(press(key::RETURN, NONE, "\r").as_deref(), Some("\r"));
        assert_eq!(press(key::BACKSPACE, NONE, "").as_deref(), Some("\u{7f}"));
        assert_eq!(press(key::TAB, NONE, "\t").as_deref(), Some("\t"));
        assert_eq!(
            press(key::BACKTAB, Modifiers::SHIFT, "").as_deref(),
            Some("\u{1b}[Z")
        );
        assert_eq!(press(key::DELETE, NONE, "").as_deref(), Some("\u{1b}[3~"));
        assert_eq!(press(key::PAGE_UP, NONE, "").as_deref(), Some("\u{1b}[5~"));
    }

    #[test]
    fn cursor_keys_follow_the_application_mode_and_modifiers() {
        assert_eq!(press(key::UP, NONE, "").as_deref(), Some("\u{1b}[A"));
        let app = encode_key(key::UP, NONE, "", true).unwrap();
        assert_eq!(app, b"\x1bOA");
        assert_eq!(
            press(key::RIGHT, Modifiers::CONTROL, "").as_deref(),
            Some("\u{1b}[1;5C")
        );
        assert_eq!(
            press(key::LEFT, Modifiers::SHIFT | Modifiers::ALT, "").as_deref(),
            Some("\u{1b}[1;4D")
        );
    }

    #[test]
    fn function_keys() {
        assert_eq!(press(key::F1, NONE, "").as_deref(), Some("\u{1b}OP"));
        assert_eq!(press(key::F1 + 4, NONE, "").as_deref(), Some("\u{1b}[15~"));
        assert_eq!(
            press(key::F1 + 11, Modifiers::SHIFT, "").as_deref(),
            Some("\u{1b}[24;2~")
        );
    }

    #[test]
    fn a_bare_modifier_sends_nothing() {
        assert_eq!(press(key::SHIFT, Modifiers::SHIFT, ""), None);
        assert_eq!(press(key::CONTROL, Modifiers::CONTROL, ""), None);
    }

    #[test]
    fn mouse_reports() {
        let sgr = encode_mouse(MouseEncoding::Sgr, MouseAction::Press, 0, NONE, 4, 9);
        assert_eq!(sgr, b"\x1b[<0;5;10M");
        let up = encode_mouse(MouseEncoding::Sgr, MouseAction::Release, 0, NONE, 4, 9);
        assert_eq!(up, b"\x1b[<0;5;10m");
        let wheel = encode_mouse(
            MouseEncoding::Sgr,
            MouseAction::Press,
            4,
            Modifiers::SHIFT,
            0,
            0,
        );
        assert_eq!(wheel, b"\x1b[<68;1;1M");
        let old = encode_mouse(MouseEncoding::Default, MouseAction::Press, 2, NONE, 0, 0);
        assert_eq!(old, [0x1b, b'[', b'M', 34, 33, 33]);
        let old_up = encode_mouse(MouseEncoding::Default, MouseAction::Release, 2, NONE, 0, 0);
        assert_eq!(old_up, [0x1b, b'[', b'M', 35, 33, 33]);
    }
}
