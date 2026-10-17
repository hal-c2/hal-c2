//! `Terminals`: the route thread's terminal drawer and its sessions on the
//! MC (TerminalController.cpp, TerminalSession.cpp, features/terminal/).

use std::path::PathBuf;
use std::rc::Rc;

use hal_c2_shell::Launch;
use hal_c2_shell::controllers::keybindings::{Focus, Keymap};
use hal_c2_shell::controllers::terminals::{Session, Terminals, TerminalsObject};
use hal_c2_shell::json::Json;
use ljos::prelude::{Platform, RecordedUrls, Value};
use serde_json::json;

use crate::Hub;
use crate::common::{number, read, text};
use crate::page::{failure, last, toasts};
use crate::workspace::{
    clustered, editors, on_thread, on_thread_with, project, scratch, shell, thread,
};

const CHROME: Focus = Focus {
    terminal: false,
    composer: false,
    editable: false,
};

fn ids(hub: &Hub) -> Vec<String> {
    hub.with_controller::<Terminals, _>(|t, _| t.terminal_ids())
}

fn active(hub: &Hub) -> String {
    hub.with_controller::<Terminals, _>(|t, _| t.active_terminal_id())
}

fn is_open(hub: &Hub) -> bool {
    hub.with_controller::<Terminals, _>(|t, _| t.is_open())
}

fn session(hub: &Hub, id: &str) -> Session {
    hub.with_controller::<Terminals, _>(|t, _| t.session(id))
        .unwrap_or_else(|| panic!("no session for {id}"))
}

/// What the `Terminals` singleton says of `name`.
fn shown(hub: &Hub, name: &str) -> Value {
    read(&hub.engine, singleton(hub), name)
}

fn singleton(hub: &Hub) -> ljos::prelude::ObjectId {
    hub.engine.singleton::<TerminalsObject>().unwrap()
}

/// The `terminal` shapes followed, by terminal id.
fn attaching(hub: &Hub) -> Vec<Json> {
    hub.mc
        .subscriptions()
        .into_iter()
        .map(|(_, shape)| shape)
        .filter(|shape| shape["type"] == "terminal")
        .collect()
}

/// A frame of terminal `id`'s shape.
fn on_terminal(hub: &Hub, id: &str, event: Json) {
    hub.mc.frame_where(
        &hub.engine,
        |shape| shape["type"] == "terminal" && shape["input"]["terminalId"] == id,
        json!({"t": "terminal", "event": event}),
    );
}

fn attach(hub: &Hub, id: &str, history: &str) {
    on_terminal(
        hub,
        id,
        json!({"type": "snapshot", "snapshot": {"history": history}}),
    );
}

/// The environment's terminals list.
fn listed(hub: &Hub, event: Json) {
    hub.mc.frame(
        &hub.engine,
        "terminals",
        "env-1",
        json!({"t": "terminals", "event": event}),
    );
}

fn summary(thread: &str, id: &str, label: &str, busy: bool) -> Json {
    json!({"threadId": thread, "terminalId": id, "label": label, "hasRunningSubprocess": busy})
}

fn writes(hub: &Hub) -> Vec<String> {
    hub.mc
        .calls
        .borrow()
        .iter()
        .filter(|(_, m, _)| m == "terminal.write")
        .map(|(_, _, p)| p["data"].as_str().unwrap_or_default().to_owned())
        .collect()
}

fn count(hub: &Hub, method: &str) -> usize {
    hub.mc.methods().iter().filter(|m| *m == method).count()
}

#[test]
fn toggling_opens_the_drawer_on_its_first_terminal_where_the_thread_runs() {
    let hub = on_thread("main", Some("/w/p-wt"));
    assert_eq!(shown(&hub, "available"), Value::Bool(true));
    assert!(!is_open(&hub));
    assert!(attaching(&hub).is_empty());
    hub.dispatch("terminal.toggle", json!(null));
    assert!(is_open(&hub));
    assert_eq!(ids(&hub), ["term-1"]);
    assert_eq!(active(&hub), "term-1");
    assert_eq!(shown(&hub, "open"), Value::Bool(true));
    assert_eq!(
        text(&hub.engine, singleton(&hub), "activeTerminalId"),
        "term-1"
    );
    assert_eq!(
        attaching(&hub),
        [
            json!({"type": "terminal", "environment": "env-1", "input": {
            "threadId": "t1", "terminalId": "term-1", "cwd": "/w/p-wt", "worktreePath": "/w/p-wt",
            "env": {"HAL_C2_PROJECT_ROOT": "/w/p", "T3CODE_PROJECT_ROOT": "/w/p",
                    "HAL_C2_WORKTREE_PATH": "/w/p-wt", "T3CODE_WORKTREE_PATH": "/w/p-wt"}}})
        ]
    );
    assert!(
        hub.mc
            .subscriptions()
            .iter()
            .any(|(_, s)| *s == json!({"type": "terminals", "environment": "env-1"}))
    );
    let tabs = hub.with_controller::<Terminals, _>(|t, _| t.tabs());
    assert_eq!(tabs.len(), 1);
    assert_eq!(tabs[0].label, "Terminal 1");
    assert!(tabs[0].current);

    hub.dispatch("terminal.toggle", json!(null));
    assert!(!is_open(&hub));
    // Hidden, the terminal keeps running and stays attached.
    assert_eq!(attaching(&hub).len(), 1);
}

#[test]
fn the_keymap_knows_whether_the_drawer_is_open() {
    let hub = on_thread("main", None);
    let keymap = Keymap::of(&hub.engine);
    keymap.set_mac(&hub.engine, false);
    hub.mc.frame(
        &hub.engine,
        "config",
        "",
        json!({"t": "config.keybindings",
               "rules": [{"key": "mod+shift+u", "command": "terminal.new", "when": "terminalOpen"}]}),
    );
    assert_eq!(keymap.resolve(&hub.engine, "Ctrl+Shift+U", CHROME), "");
    hub.dispatch("terminal.toggle", json!(null));
    assert_eq!(
        keymap.resolve(&hub.engine, "Ctrl+Shift+U", CHROME),
        "terminal.new"
    );
    hub.dispatch("terminal.toggle", json!(null));
    assert_eq!(keymap.resolve(&hub.engine, "Ctrl+Shift+U", CHROME), "");
}

#[test]
fn keystrokes_wait_for_the_attach_and_go_one_request_at_a_time() {
    let hub = on_thread("main", None);
    hub.dispatch("terminal.toggle", json!(null));
    let term = session(&hub, "term-1");
    assert!(!term.attached());
    term.write(&hub.engine, "ls");
    assert!(writes(&hub).is_empty());

    attach(&hub, "term-1", "$ ");
    assert!(term.attached());
    assert_eq!(term.transcript(), "$ ");
    assert_eq!(writes(&hub), ["ls"]);
    assert_eq!(
        last(&hub, "env-1", "terminal.write"),
        json!({"threadId": "t1", "terminalId": "term-1", "data": "ls"})
    );
    term.write(&hub.engine, "\r");
    term.write(&hub.engine, "pwd\r");
    assert_eq!(writes(&hub), ["ls"]);
    hub.mc
        .answer(&hub.engine, "terminal.write", Ok(json!(null)));
    assert_eq!(writes(&hub), ["ls", "\rpwd\r"]);

    // A refused write loses what was typed after it too.
    term.write(&hub.engine, "lost");
    hub.mc
        .answer(&hub.engine, "terminal.write", Err(failure("ended")));
    assert_eq!(writes(&hub).len(), 2);

    on_terminal(&hub, "term-1", json!({"type": "output", "data": "out"}));
    assert_eq!(term.transcript(), "$ out");
    on_terminal(&hub, "term-1", json!({"type": "cleared"}));
    assert_eq!(term.transcript(), "");
}

#[test]
fn only_the_latest_size_is_sent_one_at_a_time_once_attached() {
    let hub = on_thread("main", None);
    hub.dispatch("terminal.toggle", json!(null));
    let term = session(&hub, "term-1");
    term.resize(&hub.engine, 80, 24);
    assert_eq!(count(&hub, "terminal.resize"), 0);
    attach(&hub, "term-1", "");
    assert_eq!(
        last(&hub, "env-1", "terminal.resize"),
        json!({"threadId": "t1", "terminalId": "term-1", "cols": 80, "rows": 24})
    );
    term.resize(&hub.engine, 100, 30);
    term.resize(&hub.engine, 120, 40);
    assert_eq!(count(&hub, "terminal.resize"), 1);
    hub.mc
        .answer(&hub.engine, "terminal.resize", Ok(json!(null)));
    assert_eq!(count(&hub, "terminal.resize"), 2);
    assert_eq!(last(&hub, "env-1", "terminal.resize")["cols"], 120);
    hub.mc
        .answer(&hub.engine, "terminal.resize", Ok(json!(null)));
    assert_eq!(count(&hub, "terminal.resize"), 2);

    // The next terminal opens at the size the last one settled on.
    hub.dispatch("terminal.new", json!(null));
    let shape = attaching(&hub)
        .into_iter()
        .find(|s| s["input"]["terminalId"] == "term-2")
        .unwrap();
    assert_eq!(
        (
            shape["input"]["cols"].clone(),
            shape["input"]["rows"].clone()
        ),
        (json!(120), json!(40))
    );
}

#[test]
fn a_thread_has_at_most_six_terminals_and_a_group_four() {
    let hub = on_thread("main", None);
    hub.dispatch("terminal.toggle", json!(null));
    for _ in 0..3 {
        hub.dispatch("terminal.split", json!(null));
    }
    assert_eq!(ids(&hub), ["term-1", "term-2", "term-3", "term-4"]);
    let sizes = hub.with_controller::<Terminals, _>(|t, _| t.group_sizes());
    assert_eq!(
        sizes.into_iter().collect::<Vec<_>>(),
        [("group-1".to_owned(), 4)]
    );
    hub.dispatch("terminal.splitVertical", json!(null));
    assert!(toasts(&hub).contains(&("At most 4 terminals per group.".into(), String::new())));
    assert_eq!(ids(&hub).len(), 4);

    hub.dispatch("terminal.new", json!(null));
    hub.dispatch("terminal.new", json!(null));
    assert_eq!(ids(&hub).len(), 6);
    assert_eq!(active(&hub), "term-6");
    hub.dispatch("terminal.new", json!(null));
    assert_eq!(ids(&hub).len(), 6);
    assert!(
        toasts(&hub)
            .iter()
            .any(|(t, _)| t == "At most 6 terminals per thread.")
    );

    // A split takes the direction asked for.
    hub.dispatch("terminal.close", json!({"terminalId": "term-6"}));
    let request = hub.published("confirmation")["requestId"].clone();
    hub.dispatch(
        "confirmation.answer",
        json!({"requestId": request, "accepted": true}),
    );
    hub.dispatch("terminal.splitVertical", json!({"terminalId": "term-5"}));
    let tabs = hub.with_controller::<Terminals, _>(|t, _| t.tabs());
    let split: Vec<_> = tabs.iter().filter(|t| t.group == "group-2").collect();
    assert_eq!(split.len(), 2);
    assert!(split.iter().all(|t| t.vertical));
}

#[test]
fn closing_asks_first_then_closes_and_asks_the_shell_to_leave_when_the_mc_cannot() {
    let hub = on_thread("main", None);
    hub.dispatch("terminal.toggle", json!(null));
    hub.dispatch("terminal.new", json!(null));
    assert_eq!(active(&hub), "term-2");
    hub.dispatch("terminal.close", json!(null));
    let question = hub.published("confirmation");
    assert_eq!(question["title"], "Close terminal \"Terminal 2\"?");
    assert_eq!(count(&hub, "terminal.close"), 0);

    // No: nothing closes.
    hub.dispatch(
        "confirmation.answer",
        json!({"requestId": question["requestId"], "accepted": false}),
    );
    assert_eq!(ids(&hub), ["term-1", "term-2"]);

    hub.dispatch("terminal.close", json!(null));
    let question = hub.published("confirmation");
    hub.dispatch(
        "confirmation.answer",
        json!({"requestId": question["requestId"], "accepted": true}),
    );
    assert_eq!(
        last(&hub, "env-1", "terminal.close"),
        json!({"threadId": "t1", "terminalId": "term-2", "deleteHistory": true})
    );
    assert_eq!(ids(&hub), ["term-1"]);
    assert_eq!(active(&hub), "term-1");
    // Its id stays taken until the MC lets go of it.
    hub.dispatch("terminal.new", json!(null));
    assert_eq!(ids(&hub), ["term-1", "term-3"]);
    hub.mc
        .answer(&hub.engine, "terminal.close", Err(failure("no session")));
    assert_eq!(
        last(&hub, "env-1", "terminal.write"),
        json!({"threadId": "t1", "terminalId": "term-2", "data": "exit\n"})
    );

    // The last one closing hides the drawer.
    for id in ["term-3", "term-1"] {
        hub.dispatch("terminal.close", json!({"terminalId": id}));
        let question = hub.published("confirmation");
        hub.dispatch(
            "confirmation.answer",
            json!({"requestId": question["requestId"], "accepted": true}),
        );
    }
    assert!(ids(&hub).is_empty());
    assert!(!is_open(&hub));
}

#[test]
fn a_shell_that_ends_takes_its_terminal_with_it() {
    let hub = on_thread("main", None);
    hub.dispatch("terminal.toggle", json!(null));
    hub.dispatch("terminal.new", json!(null));
    attach(&hub, "term-2", "");
    on_terminal(&hub, "term-2", json!({"type": "exited"}));
    assert!(session(&hub, "term-1").subscribed());
    assert_eq!(
        last(&hub, "env-1", "terminal.close")["terminalId"],
        "term-2"
    );
    assert_eq!(ids(&hub), ["term-1"]);
}

#[test]
fn the_environments_list_names_and_ends_terminals() {
    let hub = on_thread("main", None);
    listed(
        &hub,
        json!({"type": "snapshot", "terminals": [summary("t1", "term-3", "build", true),
                                                  summary("t9", "term-1", "", false)]}),
    );
    assert_eq!(ids(&hub), ["term-3"]);
    // Not shown until the drawer opens, and then on the MC's terminal.
    assert!(attaching(&hub).is_empty());
    hub.dispatch("terminal.toggle", json!(null));
    assert_eq!(ids(&hub), ["term-3"]);
    let tabs = hub.with_controller::<Terminals, _>(|t, _| t.tabs());
    assert_eq!((tabs[0].label.as_str(), tabs[0].busy), ("build", true));

    listed(
        &hub,
        json!({"type": "upsert", "terminal": summary("t1", "term-4", "", false)}),
    );
    assert_eq!(ids(&hub), ["term-3", "term-4"]);
    listed(
        &hub,
        json!({"type": "remove", "threadId": "t1", "terminalId": "term-3"}),
    );
    assert_eq!(ids(&hub), ["term-4"]);
    assert_eq!(active(&hub), "term-4");
    listed(
        &hub,
        json!({"type": "remove", "threadId": "t1", "terminalId": "term-4"}),
    );
    assert!(!is_open(&hub));
}

#[test]
fn a_thread_left_keeps_its_terminals_attached_for_the_return() {
    let hub = clustered(Launch::default());
    shell(
        &hub,
        vec![
            project(json!({})),
            thread("t1", "main", None),
            thread("t2", "main", None),
        ],
    );
    hub.dispatch("thread.open", json!({"key": "env-1:t1"}));
    hub.dispatch("terminal.toggle", json!(null));
    let first = session(&hub, "term-1");
    attach(&hub, "term-1", "hello");

    hub.dispatch("thread.open", json!({"key": "env-1:t2"}));
    assert_eq!(
        hub.with_controller::<Terminals, _>(|t, _| t.thread_key().to_owned()),
        "env-1:t2"
    );
    assert!(!is_open(&hub));
    assert!(first.subscribed());
    assert_eq!(attaching(&hub).len(), 1);

    hub.dispatch("thread.open", json!({"key": "env-1:t1"}));
    assert!(is_open(&hub));
    assert_eq!(session(&hub, "term-1"), first);
    assert_eq!(first.transcript(), "hello");
    assert_eq!(attaching(&hub).len(), 1);

    // A page with no thread keeps them too; a closed MC terminal ends one.
    hub.dispatch("usage.open", json!({}));
    assert!(!hub.with_controller::<Terminals, _>(|t, _| t.available()));
    on_terminal(&hub, "term-1", json!({"type": "closed"}));
    assert!(!first.subscribed());
}

#[test]
fn a_project_action_runs_in_the_active_terminal() {
    let hub = clustered(Launch::default());
    let scripts = json!({"scripts": [{"id": "test", "name": "Test", "command": "npm test",
        "icon": "test", "runOnWorktreeCreate": false}]});
    shell(&hub, vec![project(scripts), thread("t1", "main", None)]);
    hub.dispatch("thread.open", json!({"key": "env-1:t1"}));
    assert_eq!(hub.published("workspace")["scripts"][0]["id"], "test");

    hub.dispatch("workspace.runScript", json!({"scriptId": "test"}));
    assert!(is_open(&hub));
    assert_eq!(
        last(&hub, "env-1", "terminal.open"),
        json!({"threadId": "t1", "terminalId": "term-1", "cwd": "/w/p",
               "env": {"HAL_C2_PROJECT_ROOT": "/w/p", "T3CODE_PROJECT_ROOT": "/w/p"}})
    );
    // Offered first next time.
    assert_eq!(hub.published("workspace")["preferredScriptId"], "test");
    hub.mc.answer(&hub.engine, "terminal.open", Ok(json!({})));
    // Typed once the terminal is attached.
    assert!(writes(&hub).is_empty());
    attach(&hub, "term-1", "");
    assert_eq!(writes(&hub), ["npm test\r"]);

    // A busy one: the action gets a terminal of its own.
    listed(
        &hub,
        json!({"type": "snapshot", "terminals": [summary("t1", "term-1", "npm", true)]}),
    );
    hub.dispatch("workspace.runScript", json!({"scriptId": "test"}));
    assert_eq!(last(&hub, "env-1", "terminal.open")["terminalId"], "term-2");
    hub.mc
        .answer(&hub.engine, "terminal.open", Err(failure("no shell")));
    assert!(toasts(&hub).contains(&("Failed to run script \"Test\".".into(), "no shell".into())));
}

#[test]
fn a_followed_link_opens_in_the_browser_or_the_editor() {
    let launch = Launch {
        config_dir: Some(scratch("terminal-links")),
        ..Launch::default()
    };
    let hub = on_thread_with(launch, "main", None);
    let opened = RecordedUrls::default();
    Platform::of(&hub.engine).set_open_url(Rc::new(opened.clone()));
    hub.dispatch("terminal.toggle", json!(null));
    hub.dispatch(
        "terminal.followLink",
        json!({"kind": "url", "text": "https://example.com/a", "cwd": ""}),
    );
    hub.dispatch(
        "terminal.followLink",
        json!({"kind": "url", "text": "file:///etc/passwd", "cwd": ""}),
    );
    assert_eq!(opened.urls(), ["https://example.com/a"]);

    hub.dispatch(
        "terminal.followLink",
        json!({"kind": "path", "text": "src/a.rs:3:4", "cwd": ""}),
    );
    assert!(toasts(&hub).contains(&(
        "Unable to open path".into(),
        "This environment has no editor to open /w/p/src/a.rs in.".into()
    )));
    editors(&hub, &["zed"]);
    hub.dispatch(
        "terminal.followLink",
        json!({"kind": "path", "text": "../b.rs:9", "cwd": "file://host/w/p/sub%20dir"}),
    );
    assert_eq!(
        last(&hub, "env-1", "shell.openInEditor"),
        json!({"cwd": "/w/p/b.rs:9", "editor": "zed"})
    );
}

#[test]
fn the_drawer_height_and_each_threads_drawer_survive_a_restart() {
    let dir: PathBuf = scratch("terminal-store");
    let launch = || Launch {
        state_dir: Some(dir.clone()),
        ..Launch::default()
    };
    {
        let hub = on_thread_with(launch(), "main", None);
        hub.dispatch("terminal.toggle", json!(null));
        hub.dispatch("terminal.resize", json!({"height": 120}));
        assert_eq!(hub.with_controller::<Terminals, _>(|t, _| t.height()), 180);
        hub.dispatch("terminal.resize", json!({"height": 412.4}));
    }
    let stored: Json =
        serde_json::from_slice(&std::fs::read(dir.join("shell-terminals.json")).unwrap()).unwrap();
    assert_eq!(
        stored,
        json!({"height": 412, "threads": [{"threadKey": "env-1:t1", "open": true, "active": "term-1"}]})
    );

    let hub = on_thread_with(launch(), "main", None);
    assert_eq!(number(&hub.engine, singleton(&hub), "height"), 412.0);
    // Remembered open, it waits to hear the MC still runs the terminal.
    assert!(!is_open(&hub));
    listed(
        &hub,
        json!({"type": "snapshot", "terminals": [summary("t1", "term-1", "", false)]}),
    );
    assert!(is_open(&hub));
    assert_eq!(active(&hub), "term-1");
}

#[test]
fn a_remembered_drawer_whose_terminals_ended_stays_shut() {
    let dir: PathBuf = scratch("terminal-store-ended");
    std::fs::write(
        dir.join("shell-terminals.json"),
        r#"{"height": 300, "threads": [{"threadKey": "env-1:t1", "open": true, "active": "term-1"}]}"#,
    )
    .unwrap();
    let hub = on_thread_with(
        Launch {
            state_dir: Some(dir),
            ..Launch::default()
        },
        "main",
        None,
    );
    listed(&hub, json!({"type": "snapshot", "terminals": []}));
    assert!(!is_open(&hub));
    assert!(ids(&hub).is_empty());
}
