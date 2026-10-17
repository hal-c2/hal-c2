//! `quit`: the quit shortcut, guarded as `confirmQuit` says
//! (features/navigation/windows.feature, "Quitting and the application
//! menu"). Key events go in as the window would offer them; the clock is
//! virtual.

use std::cell::Cell;
use std::path::PathBuf;
use std::rc::Rc;

use hal_c2_shell::Launch;
use hal_c2_shell::commands::Commands;
use hal_c2_shell::controllers::keybindings::Keymap;
use hal_c2_shell::controllers::quit::{self, Mode, QuitController};
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::keybindings::qt;
use ljos::keys::{KeyEvent, Modifiers};
use serde_json::json;

use crate::Hub;

/// A shell whose `confirmQuit` is `mode` (unset for `None`), with what it
/// asked of the app counted: quits, then concealments.
struct Quitting {
    hub: Hub,
    quits: Rc<Cell<u32>>,
    conceals: Rc<Cell<u32>>,
}

fn quitting(test: &str, mode: Option<serde_json::Value>) -> Quitting {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join("hub-quit")
        .join(test);
    let _ = std::fs::remove_dir_all(&dir);
    let hub = Hub::with(Launch {
        config_dir: Some(dir),
        ..Launch::default()
    });
    Keymap::of(&hub.engine).set_mac(&hub.engine, false);
    if let Some(mode) = mode {
        assert!(Settings::of(&hub.engine).write_device(&hub.engine, "confirmQuit", mode));
    }
    let quits = Rc::new(Cell::new(0));
    let conceals = Rc::new(Cell::new(0));
    let (q, c) = (quits.clone(), conceals.clone());
    hub.with_controller::<QuitController, _>(|quit, _| {
        quit.on_quit(move |_| q.set(q.get() + 1));
        quit.on_conceal(move |_| c.set(c.get() + 1));
    });
    Quitting {
        hub,
        quits,
        conceals,
    }
}

fn mod_q() -> KeyEvent {
    KeyEvent::press(qt::KEY_Q).with_modifiers(Modifiers::CONTROL)
}

impl Quitting {
    fn key(&self, ev: KeyEvent) -> bool {
        quit::filter(&self.hub.engine, &ev)
    }

    /// Control, then Q, as a press of mod+Q starts.
    fn press(&self) -> bool {
        self.key(KeyEvent::press(qt::KEY_CONTROL).with_modifiers(Modifiers::CONTROL));
        self.key(mod_q())
    }

    fn repeat(&self) -> bool {
        self.key(mod_q().repeated())
    }

    fn release_q(&self) {
        self.key(KeyEvent::release(qt::KEY_Q).with_modifiers(Modifiers::CONTROL));
    }

    fn release_mod(&self) {
        self.key(KeyEvent::release(qt::KEY_CONTROL));
    }

    /// A quick press: down and up again.
    fn tap(&self) {
        assert!(self.press());
        self.release_q();
        self.release_mod();
    }

    /// Holds Q for `ms`, auto-repeating every 30ms as a keyboard does.
    fn hold_for(&self, ms: u64) {
        let mut held = 0;
        while held < ms {
            self.hub.advance(30);
            held += 30;
            assert!(self.repeat(), "a repeat of the shortcut is its own");
        }
    }

    fn hint(&self) -> serde_json::Value {
        self.hub.published("quitHint")
    }

    fn quits(&self) -> u32 {
        self.quits.get()
    }
}

#[test]
fn the_mode_follows_the_setting_and_the_old_boolean() {
    assert_eq!(Mode::of(None), Mode::Hold);
    assert_eq!(Mode::of(Some(&json!("hold"))), Mode::Hold);
    assert_eq!(Mode::of(Some(&json!("double-click"))), Mode::DoublePress);
    assert_eq!(Mode::of(Some(&json!("direct"))), Mode::Direct);
    assert_eq!(Mode::of(Some(&json!(true))), Mode::Hold);
    assert_eq!(Mode::of(Some(&json!(false))), Mode::Direct);
    assert_eq!(Mode::of(Some(&json!("sideways"))), Mode::Hold);
}

#[test]
fn no_hint_shows_until_the_shortcut_is_pressed() {
    let q = quitting("no-hint", None);
    assert_eq!(q.hint(), json!(null));
}

#[test]
fn holding_the_quit_shortcut_quits() {
    let q = quitting("hold", Some(json!("hold")));
    assert!(q.press());
    q.hold_for(1200);
    assert_eq!(q.conceals.get(), 1, "a finished hold hides the window");
    assert_eq!(q.quits(), 0, "not while the key is still down");
    q.release_q();
    assert_eq!(q.quits(), 1);
    assert!(q.hub.engine.quit_requested());
}

#[test]
fn a_finished_hold_quits_once_the_keys_go_quiet() {
    let q = quitting("hold-quiet", None);
    assert!(q.press());
    q.hold_for(1200);
    // The key's release never arrives (focus moved): the repeats stopping
    // is enough. Two 30ms cadences are less than the grace.
    q.hub.advance(599);
    assert_eq!(q.quits(), 0);
    q.hub.advance(1);
    assert_eq!(q.quits(), 1);
}

#[test]
fn the_repeats_of_a_finished_hold_push_the_quit_back() {
    let q = quitting("hold-repeats", None);
    assert!(q.press());
    q.hold_for(1200);
    // Still down: each repeat restarts the quiet period, and is claimed.
    q.hold_for(900);
    assert_eq!(q.quits(), 0);
    // Letting go of mod first waits for the quiet period too.
    q.release_mod();
    q.hub.advance(599);
    assert_eq!(q.quits(), 0);
    q.hub.advance(1);
    assert_eq!(q.quits(), 1);
}

#[test]
fn a_hold_without_auto_repeat_never_quits() {
    let q = quitting("hold-no-repeat", None);
    assert!(q.press());
    // Repeat is off: the key may be down, but nothing proves it.
    q.hub.advance(1799);
    assert!(q.hint().is_object());
    // Given up after the hold and its grace; the hint lingers after that.
    q.hub.advance(1);
    q.hub.advance(1199);
    assert!(q.hint().is_object());
    q.hub.advance(1);
    assert_eq!(q.hint(), json!(null));
    assert_eq!(q.quits(), 0);
    assert_eq!(q.conceals.get(), 0);
    // So a late repeat completes nothing.
    assert!(q.repeat());
    assert_eq!(q.conceals.get(), 0);
}

#[test]
fn a_hold_too_short_does_not_quit() {
    let q = quitting("hold-short", None);
    assert!(q.press());
    q.hold_for(900);
    q.release_q();
    q.release_mod();
    q.hub.advance(5000);
    assert_eq!(q.quits(), 0);
}

#[test]
fn pressing_the_quit_shortcut_twice_quits() {
    let q = quitting("twice", Some(json!("hold")));
    q.tap();
    q.hub.advance(500);
    assert!(q.press());
    assert_eq!(q.quits(), 1);
}

#[test]
fn two_presses_too_far_apart_do_not_quit() {
    let q = quitting("twice-slow", None);
    q.tap();
    q.hub.advance(501);
    assert!(q.press());
    assert_eq!(q.quits(), 0);
}

#[test]
fn a_single_quick_press_shows_the_hint_and_does_not_quit() {
    let q = quitting("single", Some(json!("hold")));
    q.tap();
    assert_eq!(q.quits(), 0);
    assert_eq!(
        q.hint(),
        json!({"message": "Hold Ctrl+Q or press twice to quit"})
    );
    // Letting go ends the press; the hint lingers as long as a hold takes.
    q.hub.advance(1199);
    assert_eq!(q.hint()["message"], "Hold Ctrl+Q or press twice to quit");
    q.hub.advance(1);
    assert_eq!(q.hint(), json!(null));
    assert_eq!(q.quits(), 0);
}

#[test]
fn the_hint_names_the_shortcut_as_macos_does() {
    let q = quitting("mac", None);
    Keymap::of(&q.hub.engine).set_mac(&q.hub.engine, true);
    q.tap();
    let label = Keymap::of(&q.hub.engine).key_label("mod+q");
    assert_eq!(
        q.hint()["message"],
        format!("Hold {label} or press twice to quit")
    );
}

#[test]
fn double_press_mode_asks_for_a_second_press() {
    let q = quitting("double", Some(json!("double-click")));
    q.tap();
    assert_eq!(q.hint(), json!({"message": "Press Ctrl+Q again to quit"}));
    assert_eq!(q.quits(), 0);
    // Letting go keeps the hint until the half second is up, then it goes
    // at once.
    q.hub.advance(499);
    assert!(q.hint().is_object());
    q.hub.advance(1);
    assert_eq!(q.hint(), json!(null));
}

#[test]
fn double_press_mode_quits_on_the_second_press() {
    let q = quitting("double-twice", Some(json!("double-click")));
    q.tap();
    q.hub.advance(300);
    assert!(q.press());
    assert_eq!(q.quits(), 1);
}

#[test]
fn double_press_mode_does_not_quit_on_a_hold() {
    let q = quitting("double-hold", Some(json!("double-click")));
    assert!(q.press());
    q.hold_for(2400);
    q.release_q();
    q.hub.advance(5000);
    assert_eq!(q.quits(), 0);
    assert_eq!(q.conceals.get(), 0);
}

#[test]
fn direct_mode_quits_on_one_press() {
    let q = quitting("direct", Some(json!("direct")));
    assert!(q.press());
    assert_eq!(q.quits(), 1);
    assert_eq!(q.hint(), json!(null));
}

#[test]
fn the_old_boolean_setting_still_counts() {
    let q = quitting("boolean", Some(json!(false)));
    assert!(q.press());
    assert_eq!(q.quits(), 1);
}

#[test]
fn pressing_another_key_cancels_a_quit_in_progress() {
    let q = quitting("cancel", None);
    assert!(q.press());
    q.hold_for(600);
    assert!(!q.key(KeyEvent::press(0x41)), "another key is the window's");
    q.hold_for(900);
    assert_eq!(q.conceals.get(), 0);
    q.release_q();
    q.release_mod();
    // The first press is forgotten, so a following press starts over.
    q.hub.advance(100);
    assert!(q.press());
    assert_eq!(q.quits(), 0);
    assert!(q.hint().is_object());
}

#[test]
fn mod_with_another_modifier_is_not_the_shortcut() {
    let q = quitting("shifted", Some(json!("direct")));
    let shifted = KeyEvent::press(qt::KEY_Q).with_modifiers(Modifiers::CONTROL | Modifiers::SHIFT);
    assert!(!q.key(shifted));
    assert!(!q.key(KeyEvent::press(qt::KEY_Q)));
    assert_eq!(q.quits(), 0);
}

#[test]
fn quit_from_the_command_palette_is_immediate() {
    let q = quitting("palette", Some(json!("hold")));
    let commands = Commands::of(&q.hub.engine);
    assert!(commands.contains(&q.hub.engine, quit::QUIT));
    assert_eq!(commands.terms(quit::QUIT), vec!["quit", "exit"]);
    let row = commands
        .rows()
        .into_iter()
        .find(|r| r.command == quit::QUIT)
        .expect("app.quit is listed");
    assert_eq!(row.title, "Quit HAL-C2");
    assert!(commands.run(&q.hub.engine, quit::QUIT));
    assert_eq!(q.quits(), 1);
}

#[test]
fn quitting_mid_hold_clears_the_hold() {
    let q = quitting("palette-mid-hold", None);
    assert!(q.press());
    q.hold_for(300);
    assert!(Commands::of(&q.hub.engine).run(&q.hub.engine, quit::QUIT));
    assert_eq!(q.quits(), 1);
    // Nothing of the hold is left to complete.
    q.hold_for(1500);
    assert_eq!(q.conceals.get(), 0);
}
