//! EnvironmentSettings over a scripted MC: the settings documents of a few
//! environments, read as one value and changed on each.

#[path = "support/scripted_mc.rs"]
mod scripted_mc;

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use hal_c2_shell::environment_settings::{Edit, EnvironmentSettings, Outcome, at, same_json, with};
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::McError;
use scripted_mc::{ScriptedMc, stale};
use serde_json::json;

fn shape(environment: &str) -> Json {
    json!({ "type": "config", "environment": environment })
}

fn ids(ids: &[&str]) -> Vec<String> {
    ids.iter().map(|s| s.to_string()).collect()
}

fn idle() -> Rc<ScriptedMc> {
    ScriptedMc::new(|_, _, _| Err(McError::new("unexpected")))
}

#[test]
fn a_target_answers_with_its_config_and_then_its_settings() {
    let engine = ljos::engine();
    let mc = idle();
    let scope = EnvironmentSettings::new(mc.clone());
    let changed = Rc::new(Cell::new(0));
    scope.on_changed({
        let changed = changed.clone();
        move |_| changed.set(changed.get() + 1)
    });

    assert!(scope.set_targets(&ids(&["a", "", "a", "b"])));
    assert_eq!(scope.targets(), ids(&["a", "b"]));
    assert_eq!(mc.subscribed(), [shape("a"), shape("b")]);
    // Following the same targets again changes nothing, and the listener is
    // never called for a target change.
    assert!(!scope.set_targets(&ids(&["a", "b"])));
    assert_eq!(changed.get(), 0);
    assert!(!scope.ready());

    mc.send(
        &engine,
        &shape("a"),
        json!({ "t": "config", "config": { "settings": { "x": 1 } } }),
    );
    assert_eq!(scope.settings("a"), Some(json!({ "x": 1 })));
    assert!(!scope.ready());
    mc.send(
        &engine,
        &shape("b"),
        json!({ "t": "config.settings", "settings": { "x": 2 } }),
    );
    assert!(scope.ready());
    assert_eq!(changed.get(), 2);

    // The same document again is not a change; a frame of anything else
    // (providers) is not a document at all.
    mc.send(
        &engine,
        &shape("a"),
        json!({ "t": "config.settings", "settings": { "x": 1.0 } }),
    );
    mc.send(
        &engine,
        &shape("a"),
        json!({ "t": "config.providers", "providers": [] }),
    );
    assert_eq!(changed.get(), 2);
}

#[test]
fn every_frame_reaches_the_frame_listener_before_the_change() {
    let engine = ljos::engine();
    let mc = idle();
    let scope = EnvironmentSettings::new(mc.clone());
    let seen = Rc::new(RefCell::new(Vec::<String>::new()));
    scope.on_frame({
        let seen = seen.clone();
        move |_, id, frame| seen.borrow_mut().push(format!("frame {id} {}", frame["t"]))
    });
    scope.on_changed({
        let seen = seen.clone();
        move |_| seen.borrow_mut().push("changed".into())
    });
    scope.set_targets(&ids(&["a"]));
    mc.send(&engine, &shape("a"), json!({ "t": "config.providers" }));
    mc.send(
        &engine,
        &shape("a"),
        json!({ "t": "config.settings", "settings": {} }),
    );
    assert_eq!(
        *seen.borrow(),
        [
            "frame a \"config.providers\"",
            "frame a \"config.settings\"",
            "changed"
        ]
    );
}

#[test]
fn a_reading_is_the_first_value_and_says_when_others_differ() {
    let engine = ljos::engine();
    let mc = idle();
    let scope = EnvironmentSettings::new(mc.clone());
    scope.set_targets(&ids(&["a", "b", "c"]));
    let reading = scope.read_path("a.b");
    assert_eq!(
        (reading.known, reading.mixed, reading.value),
        (0, false, None)
    );

    mc.send(
        &engine,
        &shape("b"),
        json!({ "t": "config.settings", "settings": { "a": { "b": 3 } } }),
    );
    let reading = scope.read_path("a.b");
    assert_eq!(
        (reading.known, reading.mixed, reading.value),
        (1, false, Some(json!(3)))
    );

    // 3 and 3.0 are one value; a target without the setting is another.
    mc.send(
        &engine,
        &shape("a"),
        json!({ "t": "config.settings", "settings": { "a": { "b": 3.0 } } }),
    );
    assert!(!scope.read_path("a.b").mixed);
    mc.send(
        &engine,
        &shape("c"),
        json!({ "t": "config.settings", "settings": {} }),
    );
    let reading = scope.read_path("a.b");
    assert_eq!((reading.known, reading.mixed), (3, true));
    // The first target (not the first to answer) is the one to show.
    assert_eq!(reading.value, Some(json!(3.0)));
}

#[test]
fn dropping_targets_and_the_scope_unsubscribes() {
    let mc = idle();
    let scope = EnvironmentSettings::new(mc.clone());
    scope.set_targets(&ids(&["a", "b"]));
    assert!(scope.set_targets(&ids(&["b"])));
    assert_eq!(mc.subscribed(), [shape("b")]);
    drop(scope);
    assert!(mc.subscribed().is_empty());
}

fn set(path: &'static str, value: Json) -> Edit {
    Rc::new(move |settings, _| with(settings, path, Some(value.clone())))
}

fn following(
    mc: &Rc<ScriptedMc>,
    engine: &ljos::prelude::Engine,
    targets: &[&str],
) -> EnvironmentSettings {
    let scope = EnvironmentSettings::new(mc.clone());
    scope.set_targets(&ids(targets));
    for id in targets {
        mc.send(
            engine,
            &shape(id),
            json!({ "t": "config.settings", "settings": {} }),
        );
    }
    scope
}

fn collect(
    outcome: &Rc<RefCell<Option<Outcome>>>,
) -> impl FnOnce(&ljos::prelude::Engine, Outcome) + 'static {
    let outcome = outcome.clone();
    move |_, o| *outcome.borrow_mut() = Some(o)
}

#[test]
fn a_change_reads_then_writes_each_target_at_its_own_version() {
    let engine = ljos::engine();
    let mc = ScriptedMc::new(|env, method, payload| match method {
        "hal-c2.readSettings" => Ok(json!({
            "settings": { "keep": env },
            "version": format!("v-{env}"),
        })),
        "hal-c2.writeSettings" => {
            assert!(payload["version"].as_str().unwrap().starts_with("v-"));
            Ok(json!({}))
        }
        other => panic!("{other}"),
    });
    let scope = following(&mc, &engine, &["a", "b"]);
    let outcome = Rc::new(RefCell::new(None));
    assert!(
        scope
            .change(set("n.m", json!(7)), collect(&outcome))
            .is_ok()
    );
    // Nothing is answered inside the call.
    assert!(outcome.borrow().is_none());
    mc.deliver(&engine);
    assert_eq!(
        *outcome.borrow(),
        Some(Outcome {
            failed: Default::default(),
            saved: 2
        })
    );
    let writes: Vec<_> = mc
        .calls
        .borrow()
        .iter()
        .filter(|(_, m, _)| m == "hal-c2.writeSettings")
        .map(|(env, _, p)| (env.clone(), p.clone()))
        .collect();
    assert_eq!(
        writes,
        [
            (
                "a".to_string(),
                json!({ "settings": { "keep": "a", "n": { "m": 7 } }, "version": "v-a" })
            ),
            (
                "b".to_string(),
                json!({ "settings": { "keep": "b", "n": { "m": 7 } }, "version": "v-b" })
            ),
        ]
    );
}

#[test]
fn an_edit_that_changes_nothing_writes_nothing() {
    let engine = ljos::engine();
    let mc = ScriptedMc::new(|_, method, _| match method {
        "hal-c2.readSettings" => Ok(json!({ "settings": { "n": 1 }, "version": 1 })),
        other => panic!("{other}"),
    });
    let scope = following(&mc, &engine, &["a"]);
    let outcome = Rc::new(RefCell::new(None));
    scope
        .change(set("n", json!(1.0)), collect(&outcome))
        .unwrap();
    mc.deliver(&engine);
    assert_eq!(outcome.borrow().as_ref().unwrap().saved, 1);
    assert_eq!(mc.methods(), ["hal-c2.readSettings"]);
}

#[test]
fn a_stale_write_is_edited_again_up_to_three_times() {
    let engine = ljos::engine();
    let reads = Rc::new(Cell::new(0));
    let mc = ScriptedMc::new({
        let reads = reads.clone();
        move |_, method, payload| match method {
            "hal-c2.readSettings" => {
                reads.set(reads.get() + 1);
                Ok(json!({ "settings": { "seen": reads.get() }, "version": reads.get() }))
            }
            // Refused twice, then accepted at the third version.
            "hal-c2.writeSettings" if payload["version"] == json!(3) => Ok(json!({})),
            "hal-c2.writeSettings" => Err(stale()),
            other => panic!("{other}"),
        }
    });
    let scope = following(&mc, &engine, &["a"]);
    let outcome = Rc::new(RefCell::new(None));
    scope
        .change(set("x", json!(true)), collect(&outcome))
        .unwrap();
    mc.deliver(&engine);
    assert_eq!(outcome.borrow().as_ref().unwrap().saved, 1);
    assert_eq!(reads.get(), 3);
    // The last write is the edit of the last read.
    let last = mc.payloads("hal-c2.writeSettings").pop().unwrap();
    assert_eq!(last["settings"], json!({ "seen": 3, "x": true }));

    // Always stale: the first attempt and three more, then it fails.
    reads.set(100);
    mc.answers(|_, method, _| match method {
        "hal-c2.readSettings" => Ok(json!({ "settings": {}, "version": 0 })),
        _ => Err(stale()),
    });
    let outcome = Rc::new(RefCell::new(None));
    scope
        .change(set("x", json!(false)), collect(&outcome))
        .unwrap();
    mc.deliver(&engine);
    let outcome = outcome.borrow().clone().unwrap();
    assert_eq!(outcome.saved, 0);
    assert_eq!(outcome.failed["a"], "The settings changed.");
    assert_eq!(mc.payloads("hal-c2.writeSettings").len(), 3 + 4);
}

#[test]
fn one_failing_target_does_not_hide_the_others_saves() {
    let engine = ljos::engine();
    let mc = ScriptedMc::new(|env, method, _| match (env, method) {
        (_, "hal-c2.readSettings") => Ok(json!({ "settings": {}, "version": 1 })),
        ("b", _) => Err(McError::new("Disk full.")),
        _ => Ok(json!({})),
    });
    let scope = following(&mc, &engine, &["a", "b", "c"]);
    let outcome = Rc::new(RefCell::new(None));
    scope.change(set("x", json!(1)), collect(&outcome)).unwrap();
    mc.deliver(&engine);
    let outcome = outcome.borrow().clone().unwrap();
    assert_eq!(outcome.saved, 2);
    assert_eq!(
        outcome.failed.into_iter().collect::<Vec<_>>(),
        [("b".to_string(), "Disk full.".to_string())]
    );
}

#[test]
fn a_target_that_has_not_answered_is_not_connected() {
    let engine = ljos::engine();
    let mc = ScriptedMc::new(|_, method, _| match method {
        "hal-c2.readSettings" => Ok(json!({ "settings": {}, "version": 1 })),
        _ => Ok(json!({})),
    });
    let scope = EnvironmentSettings::new(mc.clone());
    scope.set_targets(&ids(&["a", "b"]));
    mc.send(
        &engine,
        &shape("a"),
        json!({ "t": "config.settings", "settings": {} }),
    );
    let outcome = Rc::new(RefCell::new(None));
    scope.change(set("x", json!(1)), collect(&outcome)).unwrap();
    mc.deliver(&engine);
    let outcome = outcome.borrow().clone().unwrap();
    assert_eq!(outcome.saved, 1);
    assert_eq!(outcome.failed["b"], "Not connected.");
    assert!(!mc.calls.borrow().iter().any(|(env, ..)| env == "b"));

    // With nobody to write, the outcome comes back at once and `done` never runs.
    let nobody = EnvironmentSettings::new(mc.clone());
    nobody.set_targets(&ids(&["z"]));
    let outcome = Rc::new(RefCell::new(None));
    let err = nobody
        .change(set("x", json!(1)), collect(&outcome))
        .unwrap_err();
    assert_eq!(err.saved, 0);
    assert_eq!(err.failed["z"], "Not connected.");
    mc.deliver(&engine);
    assert!(outcome.borrow().is_none());
}

#[test]
fn a_scope_dropped_mid_change_never_reports() {
    let engine = ljos::engine();
    let mc = ScriptedMc::new(|_, _, _| Ok(json!({ "settings": {}, "version": 1 })));
    let scope = following(&mc, &engine, &["a"]);
    let outcome = Rc::new(RefCell::new(None));
    scope.change(set("x", json!(1)), collect(&outcome)).unwrap();
    drop(scope);
    mc.deliver(&engine);
    assert!(outcome.borrow().is_none());
    assert_eq!(mc.methods(), ["hal-c2.readSettings"]);
}

#[test]
fn dotted_paths_read_and_write_nested_objects() {
    let settings = json!({ "a": { "b": 1, "c": 2 }, "d": 3 });
    assert_eq!(at(&settings, "a.b"), Some(&json!(1)));
    assert_eq!(at(&settings, "a.x"), None);
    assert_eq!(at(&settings, "d.e"), None);
    assert_eq!(
        with(settings.clone(), "a.b", Some(json!(9))),
        json!({ "a": { "b": 9, "c": 2 }, "d": 3 })
    );
    assert_eq!(
        with(settings.clone(), "a.b", None),
        json!({ "a": { "c": 2 }, "d": 3 })
    );
    assert_eq!(
        with(settings.clone(), "d", Some(Json::Null)),
        json!({ "a": { "b": 1, "c": 2 } })
    );
    // A path through something that is not an object replaces it.
    assert_eq!(
        with(settings, "d.e", Some(json!(1))),
        json!({ "a": { "b": 1, "c": 2 }, "d": { "e": 1 } })
    );
    assert!(same_json(
        &json!({ "a": [1, 2.0] }),
        &json!({ "a": [1.0, 2] })
    ));
    assert!(!same_json(&json!(1), &json!("1")));
}
