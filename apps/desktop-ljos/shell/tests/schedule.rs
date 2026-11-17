//! `schedule`: once, every period, cancelled, gone with its owner, on a
//! test window's virtual clock, counted by the fires the engine recorded
//! rather than by sleeping.

use std::cell::Cell;
use std::rc::Rc;
use std::time::Duration;

use hal_c2_shell::schedule;
use ljos::prelude::{Engine, Timer};
use ljos::testing::TestWindow;

fn engine() -> (Engine, TestWindow) {
    let engine = Engine::new();
    let window = TestWindow::new(&engine, 100.0, 100.0);
    (engine, window)
}

fn counter() -> (Rc<Cell<u32>>, impl Fn(&Engine) + Clone + 'static) {
    let count = Rc::new(Cell::new(0));
    let bump = {
        let count = count.clone();
        move |_: &Engine| count.set(count.get() + 1)
    };
    (count, bump)
}

#[test]
fn a_one_shot_fires_once_at_its_time() {
    let (engine, mut window) = engine();
    let (count, bump) = counter();
    let once = schedule::after(&engine, "test once", None, Duration::from_millis(500), bump);
    window.advance(499).unwrap();
    assert_eq!(count.get(), 0);
    assert!(once.is_pending());
    window.advance(1).unwrap();
    assert_eq!(count.get(), 1);
    assert!(!once.is_pending());
    window.advance(10_000).unwrap();
    assert_eq!(count.get(), 1);
    assert_eq!(schedule::fired(&engine).get("test once"), Some(&1));
    assert!(schedule::pending(&engine).is_empty());
    assert_eq!(engine.next_timer_deadline(), None);
}

#[test]
fn a_repeating_schedule_fires_every_period_until_cancelled() {
    let (engine, mut window) = engine();
    let (count, bump) = counter();
    let every = schedule::every(
        &engine,
        "test every",
        None,
        Duration::from_millis(100),
        bump,
    );
    window.advance(1_000).unwrap();
    assert_eq!(count.get(), 10);
    every.cancel(&engine);
    window.advance(1_000).unwrap();
    assert_eq!(count.get(), 10);
    assert_eq!(engine.next_timer_deadline(), None);
}

#[test]
fn a_cancelled_schedule_never_fires() {
    let (engine, mut window) = engine();
    let (count, bump) = counter();
    let once = schedule::after(
        &engine,
        "test cancelled",
        None,
        Duration::from_millis(50),
        bump,
    );
    once.cancel(&engine);
    window.advance(1_000).unwrap();
    assert_eq!(count.get(), 0);
    assert_eq!(schedule::fired(&engine).get("test cancelled"), None);
    assert_eq!(engine.next_timer_deadline(), None);
}

#[test]
fn a_repeating_schedule_can_cancel_itself_while_it_fires() {
    let (engine, mut window) = engine();
    let count = Rc::new(Cell::new(0));
    let me: Rc<Cell<Option<schedule::Schedule>>> = Rc::default();
    let every = {
        let (count, me) = (count.clone(), me.clone());
        schedule::every(
            &engine,
            "test self",
            None,
            Duration::from_millis(10),
            move |engine| {
                count.set(count.get() + 1);
                if count.get() == 3 {
                    schedule::clear_cell(engine, &me);
                }
            },
        )
    };
    me.set(Some(every));
    window.advance(1_000).unwrap();
    assert_eq!(count.get(), 3);
}

#[test]
fn a_schedule_goes_with_its_owner() {
    let (engine, mut window) = engine();
    let owner = engine.create_native(Timer::default(), None).unwrap();
    let (count, bump) = counter();
    let once = schedule::after(
        &engine,
        "test owned",
        Some(owner),
        Duration::from_millis(100),
        bump.clone(),
    );
    let every = schedule::every(
        &engine,
        "test owned every",
        Some(owner),
        Duration::from_millis(10),
        bump,
    );
    window.advance(25).unwrap();
    assert_eq!(count.get(), 2);
    engine.destroy(owner);
    window.advance(1_000).unwrap();
    assert_eq!(count.get(), 2);
    assert!(!once.is_pending());
    assert!(!every.is_pending());
    assert_eq!(engine.next_timer_deadline(), None);
}

#[test]
fn a_dropped_handle_still_fires() {
    let (engine, mut window) = engine();
    let (count, bump) = counter();
    drop(schedule::after(
        &engine,
        "test dropped",
        None,
        Duration::from_millis(5),
        bump,
    ));
    window.advance(10).unwrap();
    assert_eq!(count.get(), 1);
}
