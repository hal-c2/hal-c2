//! The terminal drawer, and the MC's terminals behind it
//! (features/terminal/drawer.feature): desktop-qt's TerminalSteps.cpp and
//! FakeTerminals.h. The MC's terminal manager is [`FakeTerminals`], a part
//! of the MC the other terminal steps files read through the helpers here.

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::rc::Rc;

use hal_c2_shell::controller;
use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::terminals::{Session, Tab, Terminals, TerminalsObject};
use serde_json::{Value, json};

use crate::fake_mc::FakeMc;
use crate::harness::{Failure, Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

/// A terminal the MC runs: its summary and what it printed.
#[derive(Default)]
pub struct Terminal {
    pub summary: Value,
    pub history: String,
}

/// The MC's terminal manager: terminals attach with the `terminal` shape and
/// are listed by `terminals`; `terminal.*` calls are recorded and act on them
/// the way the MC's does.
#[derive(Default)]
pub struct FakeTerminals {
    /// By "threadId/terminalId".
    pub terminals: BTreeMap<String, Terminal>,
    /// Every terminal.* call, as {method, payload}.
    pub calls: Vec<Value>,
    /// Why terminal.open fails, when it does.
    pub refuse_open: String,
    /// Why terminal.close fails, when it does.
    pub refuse_close: String,
    /// What the shell prints back when it is written exactly this.
    pub replies: HashMap<String, String>,
    /// The terminal the steps' right panel tab runs.
    pub panel_terminal: String,
}

fn str_of<'a>(value: &'a Value, key: &str) -> &'a str {
    value.get(key).and_then(Value::as_str).unwrap_or_default()
}

fn terminal_key(input: &Value) -> String {
    format!(
        "{}/{}",
        str_of(input, "threadId"),
        str_of(input, "terminalId")
    )
}

fn terminal_summary(thread_id: &str, terminal_id: &str, cwd: &str) -> Value {
    json!({
        "threadId": thread_id,
        "terminalId": terminal_id,
        "cwd": cwd,
        "worktreePath": null,
        "status": "running",
        "pid": 100,
        "exitCode": null,
        "exitSignal": null,
        "hasRunningSubprocess": false,
        "label": "",
        "updatedAt": "2026-09-23T10:00:00Z",
    })
}

/// To the `terminal` subscriptions of "threadId/terminalId".
pub fn send_terminal(mc: &mut FakeMc, key: &str, event: &Value) {
    for id in mc.subscribers("terminal") {
        if terminal_key(&mc.shape_of(id)["input"]) != key {
            continue;
        }
        mc.send(&json!({"t": "terminal", "id": id, "event": event}));
    }
}

/// To the latest `terminals` subscription.
fn send_terminals(mc: &mut FakeMc, event: &Value) {
    let Some(id) = mc.subscribers("terminals").last().copied() else {
        return;
    };
    mc.send(&json!({"t": "terminals", "id": id, "event": event}));
}

/// A terminal the MC already runs, as another client left it.
pub fn add_terminal(mc: &mut FakeMc, thread_id: &str, terminal_id: &str, label: &str, busy: bool) {
    let mut summary = terminal_summary(thread_id, terminal_id, "/work");
    summary["label"] = json!(label);
    summary["hasRunningSubprocess"] = json!(busy);
    mc.part::<FakeTerminals>().terminals.insert(
        format!("{thread_id}/{terminal_id}"),
        Terminal {
            summary: summary.clone(),
            history: String::new(),
        },
    );
    send_terminals(mc, &json!({"type": "upsert", "terminal": summary}));
}

pub fn print(mc: &mut FakeMc, thread_id: &str, terminal_id: &str, data: &str) {
    let key = format!("{thread_id}/{terminal_id}");
    mc.part::<FakeTerminals>()
        .terminals
        .entry(key.clone())
        .or_default()
        .history
        .push_str(data);
    send_terminal(mc, &key, &json!({"type": "output", "data": data}));
}

pub fn close_terminal(mc: &mut FakeMc, thread_id: &str, terminal_id: &str) {
    let key = format!("{thread_id}/{terminal_id}");
    if mc.part::<FakeTerminals>().terminals.remove(&key).is_none() {
        return;
    }
    send_terminal(mc, &key, &json!({"type": "closed"}));
    send_terminals(
        mc,
        &json!({"type": "remove", "threadId": thread_id, "terminalId": terminal_id}),
    );
}

/// The `terminal` subscriptions still attached, by terminal key.
pub fn attached(mc: &FakeMc) -> Vec<String> {
    mc.subscribers("terminal")
        .into_iter()
        .map(|id| terminal_key(&mc.shape_of(id)["input"]))
        .collect()
}

/// Opens the terminal when the input says where (as terminal.open does);
/// false when it does not exist and cannot be opened.
fn ensure_terminal(mc: &mut FakeMc, input: &Value) -> bool {
    let fake = mc.part::<FakeTerminals>();
    let key = terminal_key(input);
    if fake.terminals.contains_key(&key) {
        return true;
    }
    if input.get("cwd").is_none() || !fake.refuse_open.is_empty() {
        return false;
    }
    let summary = terminal_summary(
        str_of(input, "threadId"),
        str_of(input, "terminalId"),
        str_of(input, "cwd"),
    );
    fake.terminals.insert(
        key,
        Terminal {
            summary: summary.clone(),
            history: String::new(),
        },
    );
    send_terminals(mc, &json!({"type": "upsert", "terminal": summary}));
    true
}

fn extension(mc: &mut FakeMc) {
    mc.on_shape("terminals", |mc, id, shape| {
        // Only its own environment's list; another environment's goes to the
        // MC serving it.
        if shape["environment"] != json!(mc.environment_id) {
            mc.forget(id);
            return Ok(());
        }
        let list: Vec<Value> = mc
            .part::<FakeTerminals>()
            .terminals
            .values()
            .map(|t| t.summary.clone())
            .collect();
        send_terminals(mc, &json!({"type": "snapshot", "terminals": list}));
        Ok(())
    });
    mc.on_shape("terminal", |mc, id, shape| {
        let input = shape["input"].clone();
        if !ensure_terminal(mc, &input) {
            mc.forget(id);
            // The reason the MC could not open it, or that it has no such
            // terminal.
            let refusal = mc.part::<FakeTerminals>().refuse_open.clone();
            let reason = if refusal.is_empty() || input.get("cwd").is_none() {
                "Unknown terminal".to_owned()
            } else {
                refusal
            };
            mc.send(&json!({"t": "error", "id": id, "reason": reason}));
            return Ok(());
        }
        let terminal = &mc.part::<FakeTerminals>().terminals[&terminal_key(&input)];
        let mut snapshot = terminal.summary.clone();
        snapshot["history"] = json!(terminal.history);
        mc.send(&json!({
            "t": "terminal",
            "id": id,
            "event": {"type": "snapshot", "snapshot": snapshot},
        }));
        Ok(())
    });
    mc.on_rpc("terminal.", |mc, rpc| {
        mc.part::<FakeTerminals>()
            .calls
            .push(json!({"method": rpc.method, "payload": rpc.payload}));
        if rpc.method == "terminal.open" {
            let refusal = mc.part::<FakeTerminals>().refuse_open.clone();
            if !refusal.is_empty() {
                mc.refuse(rpc, &refusal);
                return Ok(());
            }
            ensure_terminal(mc, &rpc.payload);
        }
        let rpc = rpc.clone();
        let answer = move |mc: &mut FakeMc| {
            if !mc.current(&rpc) {
                return;
            }
            let refusal = mc.part::<FakeTerminals>().refuse_close.clone();
            if rpc.method == "terminal.close" && !refusal.is_empty() {
                mc.refuse(&rpc, &refusal);
                return;
            }
            let thread_id = str_of(&rpc.payload, "threadId").to_owned();
            let terminal_id = str_of(&rpc.payload, "terminalId").to_owned();
            if rpc.method == "terminal.close" {
                close_terminal(mc, &thread_id, &terminal_id);
            }
            mc.reply(&rpc, Value::Null);
            if rpc.method == "terminal.write" {
                let reply = mc
                    .part::<FakeTerminals>()
                    .replies
                    .get(str_of(&rpc.payload, "data"))
                    .cloned()
                    .unwrap_or_default();
                if !reply.is_empty() {
                    print(mc, &thread_id, &terminal_id, &reply);
                }
            }
        };
        if mc.holding("answers") {
            mc.defer(answer);
        } else {
            answer(mc);
        }
        Ok(())
    });
}

/// Gherkin cells and strings spell control characters as `\r` and `\n`.
pub fn unescaped(text: &str) -> String {
    text.replace("\\r", "\r").replace("\\n", "\n")
}

fn tabs_of(world: &World) -> Vec<Tab> {
    controller::with::<Terminals, _>(world.engine(), |t, _| t.tabs()).unwrap_or_default()
}

fn terminals_of<R>(world: &World, f: impl FnOnce(&Terminals) -> R) -> Option<R> {
    controller::with::<Terminals, _>(world.engine(), |t, _| f(t))
}

pub fn drawer_available(world: &World) -> bool {
    terminals_of(world, |t| t.available()).unwrap_or(false)
}

pub fn drawer_open(world: &World) -> bool {
    terminals_of(world, |t| t.is_open()).unwrap_or(false)
}

pub fn active_terminal(world: &World) -> String {
    terminals_of(world, |t| t.active_terminal_id()).unwrap_or_default()
}

pub fn active_group_size(world: &World) -> usize {
    terminals_of(world, |t| {
        t.group_sizes().get(&t.active_group()).copied().unwrap_or(0)
    })
    .unwrap_or(0)
}

pub fn tab_labels(world: &World) -> String {
    tabs_of(world)
        .iter()
        .map(|t| t.label.clone())
        .collect::<Vec<_>>()
        .join(", ")
}

pub fn terminal_session(world: &World, terminal_id: &str) -> Outcome<Session> {
    match tabs_of(world)
        .into_iter()
        .find(|t| t.terminal_id == terminal_id)
    {
        Some(Tab {
            session: Some(session),
            ..
        }) => Ok(session),
        Some(_) => fail!("{terminal_id} has no session"),
        None => fail!(
            "no tab for {terminal_id}; the tabs are {}",
            tab_labels(world)
        ),
    }
}

/// The latest `terminal` subscription for the terminal: {type, environment,
/// input}.
pub fn terminal_shape(world: &World, thread_id: &str, terminal_id: &str) -> Option<Value> {
    world.mc.subscriptions.iter().rev().find_map(|sub| {
        let shape = &sub["shape"];
        let input = &shape["input"];
        (shape["type"] == "terminal"
            && input["threadId"] == thread_id
            && input["terminalId"] == terminal_id)
            .then(|| shape.clone())
    })
}

/// The latest attach of the terminal: its launch input.
pub fn terminal_attach(world: &World, thread_id: &str, terminal_id: &str) -> Option<Value> {
    terminal_shape(world, thread_id, terminal_id).map(|shape| shape["input"].clone())
}

pub fn terminal_call(
    world: &World,
    method: &str,
    thread_id: &str,
    terminal_id: &str,
) -> Option<Value> {
    let fake = world.mc.peek::<FakeTerminals>()?;
    fake.calls.iter().find_map(|call| {
        let payload = &call["payload"];
        (call["method"] == method
            && payload["threadId"] == thread_id
            && payload["terminalId"] == terminal_id)
            .then(|| payload.clone())
    })
}

pub fn describe_terminal_calls(world: &World) -> String {
    let lines: Vec<String> = world
        .mc
        .peek::<FakeTerminals>()
        .map(|f| f.calls.iter().map(show).collect())
        .unwrap_or_default();
    if lines.is_empty() {
        "(none)".to_owned()
    } else {
        lines.join("; ")
    }
}

pub fn terminal_writes(world: &World, terminal_id: &str) -> Vec<String> {
    let Some(fake) = world.mc.peek::<FakeTerminals>() else {
        return Vec::new();
    };
    fake.calls
        .iter()
        .filter(|call| {
            call["method"] == "terminal.write" && call["payload"]["terminalId"] == terminal_id
        })
        .map(|call| text(&call["payload"]["data"]))
        .collect()
}

/// A project action's id, as the settings' action editor makes it.
pub fn action_id(name: &str) -> String {
    name.to_lowercase()
}

pub fn add_action(world: &mut World, project: &str, name: &str, command: &str) -> Outcome {
    let mut row = world
        .mc
        .projects
        .get(project)
        .cloned()
        .unwrap_or(Value::Null);
    let mut scripts = row["scripts"].as_array().cloned().unwrap_or_default();
    scripts.push(json!({
        "id": action_id(name),
        "name": name,
        "command": command,
        "icon": "play",
        "runOnWorktreeCreate": false,
    }));
    row["scripts"] = Value::Array(scripts);
    world.mc.projects.insert(project.to_owned(), row.clone());
    let mc = world.mc.name.clone();
    world
        .mc
        .send_rows(&mc, vec![json!([project, "project", row])]);
    world.sync()
}

/// Shows a thread of the project, on a worktree when given one.
pub fn show_thread(world: &mut World, project: &str, worktree: &str) -> Outcome {
    let thread_id = format!("thread-in-{project}");
    let mut row = json!({
        "id": thread_id,
        "title": "Cart",
        "projectId": project,
        "createdAt": "2026-09-23T09:00:00Z",
        "updatedAt": "2026-09-23T09:00:00Z",
    });
    if !worktree.is_empty() {
        row["worktreePath"] = json!(worktree);
    }
    world.mc.threads.insert(thread_id.clone(), row.clone());
    world.mc.send_row(&thread_id, &row);
    let key = format!("{}:{thread_id}", world.mc.environment_id);
    let route = key.clone();
    world.with::<Navigation, _>(move |n, engine| n.open(engine, Route::Thread(route)))?;
    let wanted = key.clone();
    world.wait_for_with(
        move |w| at(&w.state("workspace"), "threadKey") == &json!(wanted),
        |w| {
            format!(
                "the header to show {key}; it shows {}",
                show(&w.state("workspace"))
            )
        },
    )
}

/// The id of the thread the header shows.
pub fn shown_thread(world: &World) -> String {
    let key = text(at(&world.state("workspace"), "threadKey"));
    key.split_once(':')
        .map(|(_, id)| id.to_owned())
        .unwrap_or(key)
}

/// The thread the header shows, or one of the MC's first project shown now.
pub fn ensure_thread(world: &mut World) -> Outcome<String> {
    // A draft the window landed on is not a thread yet.
    if shown_thread(world).is_empty() || at(&world.state("route"), "kind") != "thread" {
        let project = world.mc.projects.keys().next().cloned().unwrap_or_default();
        show_thread(world, &project, "")?;
    }
    Ok(shown_thread(world))
}

/// The drawer's (or the right panel's) terminals, in order.
pub fn rows_in(world: &World, panel: bool) -> Vec<Tab> {
    tabs_of(world)
        .into_iter()
        .filter(|t| t.panel == panel)
        .collect()
}

pub fn describe_rows(world: &World) -> String {
    let lines: Vec<String> = tabs_of(world)
        .iter()
        .map(|row| {
            format!(
                "{} in {}{} at {}/{}{}{}",
                row.terminal_id,
                if row.panel { "panel " } else { "" },
                row.group,
                row.slot,
                row.span,
                if row.vertical { " stacked" } else { "" },
                if row.current { " current" } else { "" },
            )
        })
        .collect();
    format!(
        "the terminals are {}",
        if lines.is_empty() {
            "none".to_owned()
        } else {
            lines.join("; ")
        }
    )
}

/// Whether `rows` are one group of `count` laid out side by side or stacked,
/// in order.
fn one_group(rows: &[Tab], count: usize, vertical: bool) -> bool {
    if rows.len() != count {
        return false;
    }
    rows.iter().enumerate().all(|(slot, row)| {
        row.group == rows[0].group
            && row.slot == slot as i32
            && row.span == count as i32
            && row.vertical == vertical
    })
}

pub fn toast_shown(world: &World, title: &str) -> bool {
    at(&world.state("toasts"), "items")
        .as_array()
        .is_some_and(|items| items.iter().any(|item| item["title"] == title))
}

/// Waits for the toast titled `title`.
pub fn wait_for_toast(world: &mut World, title: &str) -> Outcome {
    let wanted = title.to_owned();
    world.wait_for_with(
        move |w| toast_shown(w, &wanted),
        |w| {
            format!(
                "the toast {title}; the shell shows {}",
                show(&w.state("toasts"))
            )
        },
    )
}

/// Closing a terminal asks first (terminal/tabs.feature): the user says yes.
pub fn confirm_terminal_close(world: &mut World) -> Outcome {
    let question = world.state("confirmation");
    expect!(
        question.is_object() && text(&question["title"]).starts_with("Close "),
        "closing the terminal asked {}",
        show(&question)
    );
    world.dispatch(
        "confirmation.answer",
        json!({"requestId": question["requestId"], "accepted": true}),
    )
}

fn project_row(id: &str) -> Value {
    json!({
        "id": id,
        "title": id,
        "workspaceRoot": format!("/work/{id}"),
        "scripts": [],
    })
}

/// The MC's project "p1" at /work/p1, connected, unless a Background set one
/// up.
pub fn ensure_project(world: &mut World) -> Outcome {
    if world.mc.projects.is_empty() {
        world.mc.projects.insert("p1".into(), project_row("p1"));
    }
    if world.shell_subscriptions() == 0 {
        world.connect()?;
    }
    world.sync()
}

/// Who gets the keyboard when a terminal appears (navigation/focus.feature):
/// TerminalDrawer focuses a terminal only when the controller asks
/// (focusRequested), which it does for what the user opens.
#[derive(Default)]
struct TerminalFocus {
    requested: Rc<RefCell<Vec<String>>>,
    thread: String,
}

fn focus(world: &mut World) -> &mut TerminalFocus {
    world.part::<TerminalFocus>()
}

fn dispatch(world: &mut World, action: &str, payload: Value) -> Outcome {
    world.dispatch(action, payload)?;
    // What it asked of the MC has been answered.
    world.sync()
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);

    // The terminal drawer.
    steps.step(
        &format!("the MC runs these terminals for {Q}:"),
        |world, c, table| {
            let header = &table[0];
            let column = |name: &str| header.iter().position(|h| h == name);
            for cells in &table[1..] {
                let cell = |name: &str| {
                    column(name)
                        .and_then(|i| cells.get(i))
                        .cloned()
                        .unwrap_or_default()
                };
                add_terminal(
                    &mut world.mc,
                    &c[0],
                    &cell("terminal"),
                    &cell("label"),
                    cell("busy") == "yes",
                );
            }
            world.sync()
        },
    );
    steps.step(
        &format!("the MC prints {Q} in {Q} of {Q}"),
        |world, c, _| {
            print(&mut world.mc, &c[2], &c[1], &unescaped(&c[0]));
            world.sync()
        },
    );
    steps.step(&format!("the MC closes {Q} of {Q}"), |world, c, _| {
        close_terminal(&mut world.mc, &c[1], &c[0]);
        world.sync()
    });
    steps.step("the user toggles the terminal drawer", |world, _, _| {
        dispatch(world, "terminal.toggle", json!({}))
    });
    steps.step("the user opens a new terminal", |world, _, _| {
        dispatch(world, "terminal.new", json!({}))
    });
    steps.step(&format!("the user selects {Q}"), |world, c, _| {
        dispatch(world, "terminal.select", json!({"terminalId": c[0]}))
    });
    steps.step("the user closes the active terminal", |world, _, _| {
        world.dispatch("terminal.close", json!({}))?;
        confirm_terminal_close(world)?;
        world.sync()
    });
    steps.step(&format!("the user runs the script {Q}"), |world, c, _| {
        dispatch(world, "workspace.runScript", json!({"scriptId": c[0]}))
    });

    // Project actions (files/project-scripts-and-actions.feature): the
    // header's action menu runs them in the drawer.
    steps.step(
        &format!("{Q} has the action {Q} running {Q}"),
        |world, c, _| add_action(world, &c[0], &c[1], &c[2]),
    );
    steps.step(&format!("{Q} also has the action {Q}"), |world, c, _| {
        add_action(world, &c[0], &c[1], &format!("bun {}", c[1].to_lowercase()))
    });
    steps.step(
        &format!("the user is looking at a thread in {Q} on a worktree"),
        |world, c, _| show_thread(world, &c[0], &format!("/work/{}-wt", c[0])),
    );
    steps.step(
        "the thread's terminal is running a command",
        |world, _, _| {
            let thread_id = ensure_thread(world)?;
            add_terminal(&mut world.mc, &thread_id, "term-1", "", true);
            world.sync()
        },
    );
    steps.step(
        "terminals cannot be opened for the thread",
        |world, _, _| {
            world.mc.part::<FakeTerminals>().refuse_open =
                "Terminal limit reached on this machine".to_owned();
            Ok(())
        },
    );
    steps.step(&format!("the user runs the action {Q}"), |world, c, _| {
        ensure_thread(world)?;
        dispatch(
            world,
            "workspace.runScript",
            json!({"scriptId": action_id(&c[0])}),
        )
    });
    steps.step(
        &format!("a terminal in the worktree runs {Q}"),
        |world, c, _| {
            let worktree = text(at(&world.state("workspace"), "worktreePath"));
            let thread_id = shown_thread(world);
            let command = c[0].clone();
            let (folder, wanted) = (worktree.clone(), format!("{command}\r"));
            let (id, ran) = (thread_id.clone(), command.clone());
            world.wait_for_with(
                move |w| {
                    terminal_call(w, "terminal.open", &id, "term-1")
                        .is_some_and(|open| open["cwd"] == folder)
                        && terminal_writes(w, "term-1") == [wanted.clone()]
                },
                move |w| {
                    format!(
                        "{ran} in {worktree}; the MC got {}",
                        describe_terminal_calls(w)
                    )
                },
            )
        },
    );
    steps.step(
        "the command knows the project folder and the worktree folder",
        |world, _, _| {
            let workspace = world.state("workspace");
            let open = terminal_call(world, "terminal.open", &shown_thread(world), "term-1");
            let Some(open) = open else {
                fail!("the MC got {}", describe_terminal_calls(world));
            };
            let env = &open["env"];
            expect!(
                env["HAL_C2_PROJECT_ROOT"] == *at(&workspace, "projectRoot")
                    && env["HAL_C2_WORKTREE_PATH"] == *at(&workspace, "worktreePath"),
                "the command starts with {}",
                show(env)
            );
            Ok(())
        },
    );
    steps.step(&format!("{Q} runs in a new terminal"), |world, c, _| {
        let thread_id = shown_thread(world);
        let wanted = format!("{}\r", c[0]);
        let ran = c[0].clone();
        world.wait_for_with(
            move |w| {
                terminal_call(w, "terminal.open", &thread_id, "term-2").is_some()
                    && terminal_writes(w, "term-2") == [wanted.clone()]
            },
            move |w| format!("{ran} in term-2; the MC got {}", describe_terminal_calls(w)),
        )
    });
    steps.step("the busy terminal keeps running", |world, _, _| {
        world.sync()?;
        let thread_id = shown_thread(world);
        let kept = world
            .mc
            .peek::<FakeTerminals>()
            .is_some_and(|f| f.terminals.contains_key(&format!("{thread_id}/term-1")));
        expect!(
            terminal_call(world, "terminal.close", &thread_id, "term-1").is_none()
                && terminal_writes(world, "term-1").is_empty()
                && kept,
            "the MC got {}",
            describe_terminal_calls(world)
        );
        Ok(())
    });
    steps.step(
        &format!("{Q} is offered first the next time the user runs an action in {Q}"),
        |world, c, _| {
            world.sync()?;
            let workspace = world.state("workspace");
            expect!(
                at(&workspace, "projectTitle") == &json!(c[1])
                    && at(&workspace, "preferredScriptId") == &json!(action_id(&c[0])),
                "the header shows {}",
                show(&workspace)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user is told the action {Q} failed to run"),
        |world, c, _| wait_for_toast(world, &format!("Failed to run script \"{}\".", c[0])),
    );
    steps.step(&format!("the user types {Q} in {Q}"), |world, c, _| {
        let session = terminal_session(world, &c[1])?;
        session.write(&world.engine().clone(), &unescaped(&c[0]));
        world.pump()
    });
    steps.step("the terminal drawer is unavailable", |world, _, _| {
        world.sync()?;
        expect!(!drawer_available(world), "the terminal drawer is available");
        Ok(())
    });
    steps.step("the terminal drawer is closed", |world, _, _| {
        world.wait_for("the terminal drawer to close", |w| !drawer_open(w))
    });
    steps.step(
        &format!("the terminal drawer shows the tabs {Q}"),
        |world, c, _| {
            let wanted = c[0].clone();
            world.wait_for_with(
                |w| drawer_open(w) && tab_labels(w) == wanted,
                |w| {
                    format!(
                        "the tabs {}; the drawer is {} with {}",
                        c[0],
                        if drawer_open(w) { "open" } else { "closed" },
                        tab_labels(w)
                    )
                },
            )
        },
    );
    steps.step(&format!("the active terminal is {Q}"), |world, c, _| {
        let wanted = c[0].clone();
        world.wait_for_with(
            |w| active_terminal(w) == wanted,
            |w| format!("{} to be active; it is {}", c[0], active_terminal(w)),
        )
    });
    steps.step(
        &format!("the MC attaches {Q} of {Q} in {Q}"),
        |world, c, _| {
            let (terminal, thread, cwd) = (c[0].clone(), c[1].clone(), c[2].clone());
            world.wait_for(
                &format!("{} of {} to attach in {}", c[0], c[1], c[2]),
                move |w| {
                    terminal_attach(w, &thread, &terminal).is_some_and(|input| input["cwd"] == cwd)
                },
            )
        },
    );
    steps.step(
        &format!("the MC attaches {Q} of the new thread in {Q}"),
        |world, c, _| {
            let draft = hal_c2_shell::controllers::drafts::draft(world.engine(), &world.draft_id);
            let Some(draft) = draft else {
                fail!("the window shows no new thread");
            };
            let (terminal, cwd) = (c[0].clone(), c[1].clone());
            world.wait_for(
                &format!("{} of the new thread to attach in {}", c[0], c[1]),
                move |w| {
                    terminal_attach(w, &draft.thread_id, &terminal)
                        .is_some_and(|input| input["cwd"] == cwd)
                },
            )
        },
    );
    steps.step(&format!("{Q} attaches {Q} of {Q} in {Q}"), |world, c, _| {
        let (environment, terminal, thread, cwd) =
            (c[0].clone(), c[1].clone(), c[2].clone(), c[3].clone());
        let (t2, th2) = (terminal.clone(), thread.clone());
        world.wait_for_with(
            move |w| {
                terminal_shape(w, &thread, &terminal)
                    .is_some_and(|s| s["environment"] == environment && s["input"]["cwd"] == cwd)
            },
            move |w| {
                let got = terminal_shape(w, &th2, &t2)
                    .map(|s| show(&s))
                    .unwrap_or_else(|| "nothing".to_owned());
                format!(
                    "{} to attach {} of {} in {}; got {got}",
                    c[0], c[1], c[2], c[3]
                )
            },
        )
    });
    steps.step(
        &format!("{Q} of {Q} starts with {Q} set to {Q}"),
        |world, c, _| {
            let Some(input) = terminal_attach(world, &c[1], &c[0]) else {
                fail!("{} of {} never attached", c[0], c[1]);
            };
            let value = text(&input["env"][c[2].as_str()]);
            expect!(value == c[3], "{} is \"{value}\"", c[2]);
            Ok(())
        },
    );
    steps.step(&format!("{Q} of {Q} is still attached"), |world, c, _| {
        world.sync()?;
        expect!(
            attached(&world.mc).contains(&format!("{}/{}", c[1], c[0])),
            "{} of {} was let go",
            c[0],
            c[1]
        );
        Ok(())
    });
    steps.step(
        &format!("the MC is asked to open {Q} of {Q} in {Q}"),
        |world, c, _| {
            let (terminal, thread, cwd) = (c[0].clone(), c[1].clone(), c[2].clone());
            world.wait_for_with(
                move |w| {
                    terminal_call(w, "terminal.open", &thread, &terminal)
                        .is_some_and(|p| p["cwd"] == cwd)
                },
                |w| format!("terminal.open; the MC got {}", describe_terminal_calls(w)),
            )
        },
    );
    steps.step("the MC is not asked to open a terminal", |world, _, _| {
        world.sync()?;
        let opened = world
            .mc
            .peek::<FakeTerminals>()
            .is_some_and(|f| f.calls.iter().any(|call| call["method"] == "terminal.open"));
        expect!(!opened, "the MC got {}", describe_terminal_calls(world));
        Ok(())
    });
    steps.step(
        &format!("the MC is asked to close {Q} of {Q} and delete its history"),
        |world, c, _| {
            let (terminal, thread) = (c[0].clone(), c[1].clone());
            world.wait_for_with(
                move |w| {
                    terminal_call(w, "terminal.close", &thread, &terminal)
                        .is_some_and(|p| p["deleteHistory"] == true)
                },
                |w| format!("terminal.close; the MC got {}", describe_terminal_calls(w)),
            )
        },
    );
    steps.step(
        &format!("the MC receives these writes to {Q}:"),
        |world, c, table| {
            let wanted: Vec<String> = table[1..]
                .iter()
                .map(|row| unescaped(row.first().map_or("", String::as_str)))
                .collect();
            let (terminal, count) = (c[0].clone(), wanted.len());
            world.wait_for_with(
                move |w| terminal_writes(w, &terminal).len() >= count,
                |w| format!("{count} writes; the MC got {}", describe_terminal_calls(w)),
            )?;
            world.sync()?;
            expect!(
                terminal_writes(world, &c[0]) == wanted,
                "the MC got {}",
                describe_terminal_calls(world)
            );
            Ok(())
        },
    );
    // TODO(port): modelPickerShows (ComposerPickerSteps.cpp) answers first
    // for the model picker's "shows <reason>" scenarios; call its port here
    // once it exists.
    steps.step(&format!("{Q} shows {Q}"), |world, c, _| {
        if super::composer_picker::model_picker_shows(world, &c[0], &c[1])? {
            return Ok(());
        }
        let transcript = terminal_session(world, &c[0])?.transcript();
        expect!(
            transcript.contains(&unescaped(&c[1])),
            "{} shows \"{transcript}\"",
            c[0]
        );
        Ok(())
    });

    // Split groups (terminal/tabs.feature).
    steps.step(
        "the thread's terminal is open with one terminal",
        |world, _, _| {
            ensure_project(world)?;
            ensure_thread(world)?;
            world.dispatch("terminal.toggle", json!({}))?;
            world.wait_for_with(
                |w| drawer_open(w) && rows_in(w, false).len() == 1,
                describe_rows,
            )
        },
    );
    steps.step(
        "the user splits the terminal (horizontally|vertically)",
        |world, c, _| {
            let action = if c[0] == "vertically" {
                "terminal.splitVertical"
            } else {
                "terminal.split"
            };
            dispatch(world, action, json!({}))
        },
    );
    steps.step(
        "a second terminal runs next to the first (side by side|stacked)",
        |world, c, _| {
            let stacked = c[0] == "stacked";
            let thread_id = shown_thread(world);
            world.wait_for_with(
                move |w| {
                    let rows = rows_in(w, false);
                    one_group(&rows, 2, stacked)
                        && rows[1].current
                        && active_terminal(w) == rows[1].terminal_id
                        && terminal_attach(w, &thread_id, &rows[1].terminal_id).is_some()
                },
                describe_rows,
            )
        },
    );
    steps.step("a split group with four terminals", |world, _, _| {
        ensure_project(world)?;
        ensure_thread(world)?;
        world.dispatch("terminal.toggle", json!({}))?;
        world.wait_for_with(|w| rows_in(w, false).len() == 1, describe_rows)?;
        for count in 2..=4 {
            world.dispatch("terminal.split", json!({}))?;
            world.wait_for_with(move |w| rows_in(w, false).len() == count, describe_rows)?;
        }
        expect!(
            one_group(&rows_in(world, false), 4, false) && active_group_size(world) == 4,
            "{}",
            describe_rows(world)
        );
        Ok(())
    });
    steps.step("the user cannot split that group again", |world, _, _| {
        world.dispatch("terminal.split", json!({}))?;
        world.dispatch("terminal.splitVertical", json!({}))?;
        world.sync()?;
        expect!(
            one_group(&rows_in(world, false), 4, false) && active_group_size(world) == 4,
            "{}",
            describe_rows(world)
        );
        Ok(())
    });
    steps.step(
        "the user is told the limit is 4 per group",
        |world, _, _| wait_for_toast(world, "At most 4 terminals per group."),
    );

    // The header's terminal button (navigation/layout.feature),
    // Workspace.qml's terminal.toggle.
    steps.step("the terminal is (hidden|shown)", |world, c, _| {
        ensure_thread(world)?;
        let shown = c[0] == "shown";
        if shown {
            world.dispatch("terminal.toggle", json!({}))?;
        }
        world.wait_for_with(
            move |w| {
                drawer_available(w)
                    && drawer_open(w) == shown
                    && (!shown || rows_in(w, false).len() == 1)
            },
            describe_rows,
        )
    });
    steps.step("the user (?:shows|hides) the terminal", |world, _, _| {
        dispatch(world, "terminal.toggle", json!({}))
    });
    steps.step(
        "the terminal drawer opens under the thread",
        |world, _, _| {
            let thread_id = shown_thread(world);
            world.wait_for_with(
                move |w| {
                    drawer_open(w)
                        && terminals_of(w, |t| t.thread_key().ends_with(&format!(":{thread_id}")))
                            .unwrap_or(false)
                        && terminal_attach(w, &thread_id, "term-1").is_some()
                },
                describe_rows,
            )
        },
    );
    steps.step("the terminal drawer closes", |world, _, _| {
        world.wait_for("the terminal drawer to close", |w| !drawer_open(w))
    });
    steps.step("its terminals keep running", |world, _, _| {
        world.sync()?;
        let thread_id = shown_thread(world);
        expect!(
            terminal_call(world, "terminal.close", &thread_id, "term-1").is_none()
                && attached(&world.mc).contains(&format!("{thread_id}/term-1"))
                && rows_in(world, false).len() == 1,
            "{}; the MC got {}",
            describe_rows(world),
            describe_terminal_calls(world)
        );
        Ok(())
    });

    // Right panel terminal tabs (terminal/tabs.feature,
    // navigation/layout.feature).
    fn add_panel_tab(world: &mut World) -> Outcome {
        world.dispatch("rightPanel.add", json!({"kind": "terminal"}))?;
        world.wait_for_with(|w| rows_in(w, true).len() == 1, describe_rows)?;
        let id = rows_in(world, true)[0].terminal_id.clone();
        world.mc.part::<FakeTerminals>().panel_terminal = id;
        Ok(())
    }
    fn panel(world: &World) -> String {
        show(&world.state("panel"))
    }
    steps.step(
        "the terminal tab runs a terminal of its own",
        |world, _, _| {
            let thread_id = shown_thread(world);
            world.wait_for_with(
                move |w| {
                    let rows = rows_in(w, true);
                    rows.len() == 1
                        && *at(&w.state("panel"), "activeId")
                            == json!(format!("terminal:{}", rows[0].group))
                        && terminal_attach(w, &thread_id, &rows[0].terminal_id).is_some()
                },
                |w| format!("{}; the panel shows {}", describe_rows(w), panel(w)),
            )?;
            let id = rows_in(world, true)[0].terminal_id.clone();
            world.mc.part::<FakeTerminals>().panel_terminal = id;
            Ok(())
        },
    );
    steps.step(
        "the terminal drawer still shows only its first terminal",
        |world, _, _| {
            world.sync()?;
            let rows = rows_in(world, false);
            expect!(
                drawer_open(world)
                    && rows.len() == 1
                    && rows[0].terminal_id == "term-1"
                    && active_terminal(world) == "term-1",
                "{}",
                describe_rows(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the thread has a terminal tab in the right panel",
        |world, _, _| {
            ensure_project(world)?;
            ensure_thread(world)?;
            add_panel_tab(world)
        },
    );
    steps.step("the user closes the terminal tab", |world, _, _| {
        let id = at(&world.state("panel"), "activeId").clone();
        world.dispatch("rightPanel.close", json!({"id": id}))?;
        confirm_terminal_close(world)?;
        world.sync()
    });
    steps.step(
        "the tab's terminal stops and its history is deleted",
        |world, _, _| {
            let terminal_id = world.mc.part::<FakeTerminals>().panel_terminal.clone();
            let thread_id = shown_thread(world);
            world.wait_for_with(
                move |w| {
                    terminal_call(w, "terminal.close", &thread_id, &terminal_id)
                        .is_some_and(|p| p["deleteHistory"] == true)
                        && rows_in(w, true).is_empty()
                },
                |w| {
                    format!(
                        "{}; the MC got {}",
                        describe_rows(w),
                        describe_terminal_calls(w)
                    )
                },
            )?;
            let state = world.state("panel");
            for tab in at(&state, "tabs").as_array().into_iter().flatten() {
                expect!(tab["kind"] != "terminal", "{}", show(&state));
            }
            Ok(())
        },
    );
    steps.step(
        "the user splits the terminal tab (horizontally|vertically)",
        |world, c, _| {
            let action = if c[0] == "vertically" {
                "terminal.splitVertical"
            } else {
                "terminal.split"
            };
            let id = world.mc.part::<FakeTerminals>().panel_terminal.clone();
            dispatch(world, action, json!({"terminalId": id}))
        },
    );
    steps.step(
        "the terminal tab shows two terminals (side by side|stacked)",
        |world, c, _| {
            let stacked = c[0] == "stacked";
            world.wait_for_with(
                move |w| one_group(&rows_in(w, true), 2, stacked),
                describe_rows,
            )?;
            let group = rows_in(world, true)[0].group.clone();
            expect!(
                *at(&world.state("panel"), "activeId") == json!(format!("terminal:{group}")),
                "{}",
                panel(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the terminal drawer shows none of the tab's terminals",
        |world, _, _| {
            world.sync()?;
            let panel_rows = rows_in(world, true);
            for row in rows_in(world, false) {
                for other in &panel_rows {
                    expect!(
                        row.terminal_id != other.terminal_id && row.group != other.group,
                        "{}",
                        describe_rows(world)
                    );
                }
            }
            Ok(())
        },
    );
    steps.step(
        "a terminal tab in the right panel has output",
        |world, _, _| {
            add_panel_tab(world)?;
            let thread_id = shown_thread(world);
            let terminal_id = world.mc.part::<FakeTerminals>().panel_terminal.clone();
            let key = format!("{thread_id}/{terminal_id}");
            world.wait_for_with(move |w| attached(&w.mc).contains(&key), describe_rows)?;
            print(&mut world.mc, &thread_id, &terminal_id, "built in 3s\r\n");
            let id = terminal_id.clone();
            world.wait_for_with(
                |w| {
                    terminal_session(w, &terminal_id)
                        .is_ok_and(|s| s.transcript().contains("built in 3s"))
                },
                |w| {
                    let shown = terminal_session(w, &id)
                        .map(|s| s.transcript())
                        .unwrap_or_default();
                    format!("{id} shows \"{shown}\"")
                },
            )
        },
    );
    steps.step(
        "the user closes the right panel and opens it again",
        |world, _, _| {
            dispatch(world, "rightPanel.toggle", json!({}))?;
            expect!(
                at(&world.state("panel"), "isOpen") != true,
                "{}",
                panel(world)
            );
            dispatch(world, "rightPanel.toggle", json!({}))
        },
    );
    steps.step("the terminal tab still has its output", |world, _, _| {
        let thread_id = shown_thread(world);
        let terminal_id = world.mc.part::<FakeTerminals>().panel_terminal.clone();
        let rows = rows_in(world, true);
        expect!(
            rows.len() == 1
                && rows[0].terminal_id == terminal_id
                && at(&world.state("panel"), "isOpen") == true
                && *at(&world.state("panel"), "activeId")
                    == json!(format!("terminal:{}", rows[0].group)),
            "{}; the panel shows {}",
            describe_rows(world),
            panel(world)
        );
        let transcript = terminal_session(world, &terminal_id)?.transcript();
        expect!(
            terminal_call(world, "terminal.close", &thread_id, &terminal_id).is_none()
                && attached(&world.mc).contains(&format!("{thread_id}/{terminal_id}"))
                && transcript.contains("built in 3s"),
            "the MC got {}",
            describe_terminal_calls(world)
        );
        Ok(())
    });

    // navigation/layout.feature's header: the run button runs the action the
    // user ran last in the project (or its first), its menu any of them.
    fn shown_project(world: &mut World) -> Outcome<String> {
        let thread_id = ensure_thread(world)?;
        Ok(text(&world.mc.threads[&thread_id]["projectId"]))
    }
    steps.step(
        &format!("the thread's project has the actions {Q} and {Q}"),
        |world, c, _| {
            let project = shown_project(world)?;
            for name in c {
                add_action(
                    world,
                    &project,
                    name,
                    &format!("bun {}", name.to_lowercase()),
                )?;
            }
            Ok(())
        },
    );
    steps.step("the thread's project has no actions", |world, _, _| {
        let project = shown_project(world)?;
        let scripts = &world.mc.projects[&project]["scripts"];
        expect!(
            scripts.as_array().is_none_or(Vec::is_empty),
            "the project has actions"
        );
        Ok(())
    });
    steps.step(&format!("the user last ran {Q}"), |world, c, _| {
        dispatch(
            world,
            "workspace.runScript",
            json!({"scriptId": action_id(&c[0])}),
        )?;
        // That run's command reaches the terminal first, so it is not
        // taken for the next one's.
        world.wait_for_with(
            |w| {
                w.mc.peek::<FakeTerminals>().is_some_and(|fake| {
                    fake.calls
                        .iter()
                        .any(|call| call["method"] == "terminal.write")
                })
            },
            |w| {
                format!(
                    "the last run to start; the MC got {}",
                    describe_terminal_calls(w)
                )
            },
        )?;
        world.mc.part::<FakeTerminals>().calls.clear();
        Ok(())
    });
    steps.step(
        "the user runs the action offered in the header",
        |world, _, _| {
            world.sync()?;
            let workspace = world.state("workspace");
            let scripts = at(&workspace, "scripts")
                .as_array()
                .cloned()
                .unwrap_or_default();
            expect!(
                !scripts.is_empty(),
                "the header offers no action: {}",
                show(&workspace)
            );
            // Workspace.preferredScript: the one last run, else the first.
            let preferred = &workspace["preferredScriptId"];
            let script = if preferred.is_null() {
                text(&scripts[0]["id"])
            } else {
                text(preferred)
            };
            dispatch(world, "workspace.runScript", json!({"scriptId": script}))
        },
    );
    steps.step(
        &format!("the user picks {Q} from the header's actions"),
        |world, c, _| {
            dispatch(
                world,
                "workspace.runScript",
                json!({"scriptId": action_id(&c[0])}),
            )
        },
    );
    steps.step(
        &format!("{Q} runs for the thread's workspace"),
        |world, c, _| {
            let command = format!("bun {}\r", c[0].to_lowercase());
            let workspace = world.state("workspace");
            let worktree = text(&workspace["worktreePath"]);
            let folder = if worktree.is_empty() {
                text(&workspace["projectRoot"])
            } else {
                worktree
            };
            let thread_id = shown_thread(world);
            let (wanted, place) = (command.clone(), folder.clone());
            world.wait_for_with(
                move |w| {
                    let Some(fake) = w.mc.peek::<FakeTerminals>() else {
                        return false;
                    };
                    let written: Vec<String> = fake
                        .calls
                        .iter()
                        .filter(|call| call["method"] == "terminal.write")
                        .filter_map(|call| {
                            let payload = &call["payload"];
                            let cwd = fake
                                .terminals
                                .get(&terminal_key(payload))
                                .map(|t| text(&t.summary["cwd"]))
                                .unwrap_or_default();
                            (payload["threadId"] == thread_id && cwd == place)
                                .then(|| text(&payload["data"]))
                        })
                        .collect();
                    written == [wanted.clone()]
                },
                move |w| {
                    format!(
                        "only {} in {folder}; the MC got {}",
                        command.trim(),
                        describe_terminal_calls(w)
                    )
                },
            )
        },
    );
    steps.step("the header offers no action to run", |world, _, _| {
        world.sync()?;
        let workspace = world.state("workspace");
        let none = at(&workspace, "scripts")
            .as_array()
            .is_none_or(Vec::is_empty);
        expect!(
            workspace.as_object().is_some_and(|o| !o.is_empty()) && none,
            "the header shows {}",
            show(&workspace)
        );
        Ok(())
    });

    // Who gets the keyboard when a terminal appears (navigation/focus.feature).
    steps.step("the user is typing in the composer", |world, _, _| {
        ensure_project(world)?;
        let thread_id = ensure_thread(world)?;
        focus(world).thread = thread_id.clone();
        world.wait_for("the thread's terminal drawer", drawer_available)?;
        let requested = focus(world).requested.clone();
        let object = world
            .engine()
            .singleton::<TerminalsObject>()
            .map_err(|e| Failure(format!("the terminals cannot be reached: {e:?}")))?;
        world
            .engine()
            .connect_by_name(object, "focusRequested", move |_, args| {
                let id = args.first().map(|v| v.to_js_string().to_string());
                requested.borrow_mut().push(id.unwrap_or_default());
            })
            .map_err(|e| Failure(format!("focusRequested cannot be watched: {e:?}")))?;
        let target = format!("{}:{thread_id}", world.mc.environment_id);
        world.dispatch(
            "composer.text.set",
            json!({"target": target, "text": "Add tax to", "cursor": 10}),
        )
    });
    steps.step("a terminal starts on its own", |world, _, _| {
        // One the agent or a setup script started: the MC lists it.
        let thread_id = focus(world).thread.clone();
        add_terminal(&mut world.mc, &thread_id, "term-agent", "bun dev", true);
        world.sync()
    });
    steps.step("the composer keeps keyboard focus", |world, _, _| {
        let requested = focus(world).requested.clone();
        // The drawer stays as it was and nothing asks for the keyboard.
        expect!(
            requested.borrow().is_empty() && !drawer_open(world),
            "the terminal asked for the keyboard: {} (drawer open: {})",
            requested.borrow().join(", "),
            drawer_open(world)
        );
        // Unlike when the user opens the drawer, which shows that terminal
        // and focuses it.
        world.dispatch("terminal.toggle", json!({}))?;
        world.wait_for_with(
            |w| drawer_open(w) && tabs_of(w).len() == 1,
            |w| format!("the terminal to be listed; {}", describe_rows(w)),
        )?;
        expect!(
            *requested.borrow() == ["term-agent"],
            "opening it focused {}",
            requested.borrow().join(", ")
        );
        Ok(())
    });
}
