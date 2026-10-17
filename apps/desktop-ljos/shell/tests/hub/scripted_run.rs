//! ScriptedRun: the steps of `--action` and `--key` run in the order given,
//! 1.5 s apart on the engine's clock, once the shell is active
//! (features/desktop/native-connection.feature, "A scripted run starts once
//! the MC's first snapshot is in"; the picture itself is main.rs's).

use std::cell::RefCell;
use std::rc::Rc;

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::commands::Commands;
use hal_c2_shell::scripted_run::{self, Step};
use serde_json::json;

use crate::Hub;

type Log = Rc<RefCell<Vec<String>>>;

/// A shell that logs every action it is dispatched (and handles none).
fn logged(hub: &Hub) -> Log {
    let log = Log::default();
    let seen = log.clone();
    Bridge::of(&hub.engine).add_interceptor(
        &hub.engine,
        Rc::new(move |_, action, payload| {
            seen.borrow_mut().push(format!("{action} {payload}"));
            true
        }),
    );
    log
}

fn action(spec: &str) -> Step {
    Step::action(spec).0
}

#[test]
fn steps_run_in_the_order_given_one_and_a_half_seconds_apart() {
    let hub = Hub::new();
    let log = logged(&hub);
    // A chord that is a command runs it where the keymap puts it.
    let ran = Log::default();
    let seen = ran.clone();
    Commands::of(&hub.engine).add(&hub.engine, "diff.toggle", "Toggle diff", move |_| {
        seen.borrow_mut().push("diff.toggle".into())
    });
    scripted_run::play(
        &hub.engine,
        vec![
            action("demo.first"),
            Step::Key("ctrl+d".into()),
            action(r#"demo.second={"mode":"dark"}"#),
        ],
    );
    hub.advance(1499);
    assert_eq!(*log.borrow(), Vec::<String>::new());
    hub.advance(1);
    assert_eq!(*log.borrow(), vec!["demo.first null"]);
    assert!(ran.borrow().is_empty());
    hub.advance(1500);
    assert_eq!(*ran.borrow(), vec!["diff.toggle"]);
    assert_eq!(log.borrow().len(), 1);
    hub.advance(1500);
    assert_eq!(
        *log.borrow(),
        vec!["demo.first null", r#"demo.second {"mode":"dark"}"#]
    );
}

#[test]
fn a_chord_nothing_listens_to_runs_nothing() {
    let hub = Hub::new();
    let log = logged(&hub);
    assert!(!scripted_run::run(
        &hub.engine,
        &Step::Key("Ctrl+F12".into())
    ));
    assert!(!scripted_run::run(
        &hub.engine,
        &Step::Key("Ctrl+, Ctrl+K".into())
    ));
    assert!(log.borrow().is_empty());
}

#[test]
fn an_action_step_reaches_the_bridge_with_its_payload() {
    let hub = Hub::new();
    let log = logged(&hub);
    assert!(scripted_run::run(
        &hub.engine,
        &Step::Action {
            name: "demo.third".into(),
            payload: json!({"id": "t1"})
        }
    ));
    assert_eq!(*log.borrow(), vec![r#"demo.third {"id":"t1"}"#]);
}

#[test]
fn steps_wait_for_the_mcs_first_snapshot() {
    let hub = Hub::clustered();
    let log = logged(&hub);
    let steps = vec![action("demo.first")];
    hal_c2_shell::when_active(&hub.engine, move |e| scripted_run::play(e, steps));
    hub.advance(10_000);
    assert!(log.borrow().is_empty(), "the MC has not answered yet");
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell", "mcs": [], "rows": []}),
    );
    hub.advance(1499);
    assert!(
        log.borrow().is_empty(),
        "the clock starts with the snapshot"
    );
    hub.advance(1);
    assert_eq!(*log.borrow(), vec!["demo.first null"]);
}
