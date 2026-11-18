//! A shell left alone does no work: over an hour of the test window's
//! virtual clock nothing it scheduled fires, but for the client lease once
//! an MC is there. Counted by the fires the schedules recorded by name, not
//! by sleeping.

mod common;

use std::rc::Rc;

use common::FakeMc;
use hal_c2_shell::Launch;
use hal_c2_shell::schedule;
use ljos::App;
use ljos::prelude::Engine;
use ljos::testing::TestWindow;

const HOUR_MS: u64 = 60 * 60 * 1000;

/// The work a connected shell does for itself all along.
const RECURRING: [&str; 2] = ["client activity lease", "desktop update check"];

fn shell() -> (Engine, TestWindow, Rc<FakeMc>) {
    let engine = App::new("test")
        .register(hal_c2_shell::register)
        .build_engine();
    let window = TestWindow::new(&engine, 800.0, 600.0);
    let mc = Rc::new(FakeMc::default());
    hal_c2_shell::start(&engine, &Launch::default(), mc.clone());
    (engine, window, mc)
}

/// Runs what the shell scheduled for itself on starting (offering to
/// reconnect when no MC answered, writing down what it opened): left alone
/// starts after that.
fn settle(engine: &Engine, window: &mut TestWindow) {
    window.advance(1_000).unwrap();
    for _ in 0..10 {
        let Some(&(name, due)) = schedule::pending(engine)
            .iter()
            .find(|(name, _)| !RECURRING.contains(name))
        else {
            return;
        };
        let ms = due
            .saturating_since(engine.now())
            .as_micros()
            .div_ceil(1000) as u64;
        assert!(ms <= 2 * 60 * 1000, "{name} is due in {ms}ms");
        window.advance(ms.max(1)).unwrap();
    }
    panic!(
        "the shell keeps scheduling: {:?}",
        schedule::pending(engine)
    );
}

#[test]
fn a_shell_with_no_mc_wakes_zero_times_in_an_hour() {
    let (engine, mut window, _mc) = shell();
    settle(&engine, &mut window);
    let before = schedule::fired(&engine);
    window.advance(HOUR_MS).unwrap();
    assert_eq!(schedule::fired(&engine), before, "the shell woke");
    assert_eq!(schedule::pending(&engine), vec![], "the shell would wake");
    assert!(engine.running_timers().is_empty());
}

#[test]
fn a_shell_with_an_mc_wakes_only_to_renew_its_lease() {
    let (engine, mut window, mc) = shell();
    mc.set_ready(&engine, true);
    settle(&engine, &mut window);
    let before = schedule::fired(&engine);
    window.advance(HOUR_MS).unwrap();
    let woke: Vec<(&str, u64)> = schedule::fired(&engine)
        .into_iter()
        .map(|(name, count)| (name, count - before.get(name).copied().unwrap_or(0)))
        .filter(|(_, count)| *count > 0)
        .collect();
    assert!(
        woke.iter().all(|(name, _)| RECURRING.contains(name)),
        "the shell woke for {woke:?}"
    );
    assert!(
        woke.iter()
            .any(|(name, _)| *name == "client activity lease"),
        "the lease was never renewed: {woke:?}"
    );
}
