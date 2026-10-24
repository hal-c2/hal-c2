//! The shell's keymap (controllers/keybindings.rs): pressing keys the way
//! the window's shortcuts hand them over, the rules the MC keeps in
//! keybindings.json, and Settings → Keybindings over them (desktop-qt's
//! KeybindingSteps.cpp and Keymap.h): features/navigation/keybinding*.feature,
//! desktop/native-keybindings.feature for who takes a key under focus.
//!
//! A press goes where the window sends it: with no window shortcut for the
//! sequence, or one standing down for the focused terminal, the key reaches
//! whatever has focus; otherwise `Keymap::press` runs it. An open model
//! picker takes its own chords first. A command "runs" when the shell or the
//! picker ran it.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use hal_c2_shell::commands::Commands;
use hal_c2_shell::controller;
use hal_c2_shell::controllers::drafts;
use hal_c2_shell::controllers::keybindings::{Focus, Keymap};
use hal_c2_shell::controllers::navigation::{KEYBINDINGS_SECTION, Navigation, Route};
use hal_c2_shell::controllers::palette::Palette;
use hal_c2_shell::controllers::panel::RightPanel;
use hal_c2_shell::controllers::quit::QuitController;
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::sidebar;
use hal_c2_shell::controllers::terminals::{Tab, Terminals};
use hal_c2_shell::json::Json;
use hal_c2_shell::keybindings::{self as keymap, Context, qt};
use hal_c2_shell::store;
use ljos::keys::{KeyEvent, KeyKind, Modifiers};
use serde_json::{Value, json};

use crate::brick::{self, Shown};
use crate::fake_mc::{FakeMc, Rpc};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::steps::composer_brick::press_in_composer;
use crate::steps::settings::fake_config;
use crate::world::World;
use crate::{expect, fail};

/// Where the keyboard is, and what the last press did.
#[derive(Default)]
struct Keys {
    /// All false: the native chrome.
    focus: Focus,
    mac: bool,
    picker_open: bool,
    /// The engine whose commands are followed.
    hooked: Option<usize>,
    /// Something the user did: a later "is bound to" checks instead of
    /// sets up.
    acted: bool,
    thread_shown: bool,
    /// The last press: its sequence, the commands the shell ran, the
    /// picker's command, and what received the key when the window did not
    /// take it.
    sequence: String,
    ran: Rc<RefCell<Vec<String>>>,
    picker: String,
    delivered: String,
    // Settings → Keybindings.
    query: String,
    condition: String,
    last_command: String,
    last_key: String,
}

#[derive(Default)]
struct KeyPart(Rc<RefCell<Keys>>);

fn keys(world: &mut World) -> Rc<RefCell<Keys>> {
    world.part::<KeyPart>().0.clone()
}

/// The rules other environments were asked to store, by environment.
#[derive(Default)]
struct Elsewhere(HashMap<String, Vec<Value>>);

const PATH: &str = "/home/sam/.config/hal-c2/keybindings.json";

fn keymap_of(world: &World) -> Keymap {
    Keymap::of(world.engine())
}

fn stored_rules(mc: &mut FakeMc) -> Vec<Value> {
    fake_config(mc)
        .config
        .get("keybindingRules")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
}

fn send_rules(mc: &mut FakeMc) {
    let rules = stored_rules(mc);
    for id in mc.subscribers("config") {
        if text(&mc.shape_of(id)["environment"]) != mc.environment_id {
            continue;
        }
        mc.send(&json!({"t": "config.keybindings", "id": id, "rules": rules}));
    }
}

fn refused(mc: &FakeMc, rpc: &Rpc) -> bool {
    let Some(refusal) = mc.refusals.get(&rpc.method) else {
        return false;
    };
    mc.refuse(rpc, refusal);
    true
}

/// hal-c2.upsertKeybinding as the MC does it (apps/server-ex
/// lib/hal_c2/keybindings.ex): the rules back, pushed to every client as
/// `config.keybindings`.
fn upsert(mc: &mut FakeMc, rpc: &Rpc) -> Outcome {
    if refused(mc, rpc) {
        return Ok(());
    }
    let mut rule = rpc.payload.as_object().cloned().unwrap_or_default();
    let replace = rule.remove("replace").unwrap_or(Value::Null);
    let rule = Value::Object(rule);
    if !rpc.environment.is_empty() && rpc.environment != mc.environment_id {
        // Another environment's keybindings.json.
        let rules = {
            let rules = mc
                .part::<Elsewhere>()
                .0
                .entry(rpc.environment.clone())
                .or_default();
            rules.push(rule);
            rules.clone()
        };
        mc.reply(rpc, json!({"rules": rules}));
        return Ok(());
    }
    let mut rules: Vec<Value> = stored_rules(mc)
        .into_iter()
        .filter(|value| *value != rule && *value != replace)
        .collect();
    rules.push(rule);
    if rules.len() > 256 {
        rules.drain(..rules.len() - 256);
    }
    fake_config(mc)
        .config
        .insert("keybindingRules".into(), json!(rules));
    mc.reply(rpc, json!({"rules": rules}));
    send_rules(mc);
    Ok(())
}

/// hal-c2.removeKeybinding, the same way.
fn remove(mc: &mut FakeMc, rpc: &Rpc) -> Outcome {
    if refused(mc, rpc) {
        return Ok(());
    }
    let rules: Vec<Value> = stored_rules(mc)
        .into_iter()
        .filter(|value| *value != rpc.payload)
        .collect();
    fake_config(mc)
        .config
        .insert("keybindingRules".into(), json!(rules));
    mc.reply(rpc, json!({"rules": rules}));
    send_rules(mc);
    Ok(())
}

fn connected(world: &World) -> bool {
    world.shell_subscriptions() > 0
}

fn ensure_shell(world: &mut World) -> Outcome {
    if !connected(world) {
        world.connect()?;
        world.wait_for("the shell to start", |w| w.active())?;
    }
    world.sync()?;
    let state = keys(world);
    let engine = world.engine() as *const _ as usize;
    if state.borrow().hooked != Some(engine) {
        state.borrow_mut().hooked = Some(engine);
        let ran = state.borrow().ran.clone();
        Commands::of(world.engine()).on_ran(move |_, command| {
            ran.borrow_mut().push(command.to_owned());
        });
    }
    Ok(())
}

/// The MC's keybindings.json becomes `rules`, pushed when the shell is
/// connected and in the snapshot when it connects.
fn set_rules(world: &mut World, rules: Vec<Value>) -> Outcome {
    fake_config(&mut world.mc)
        .config
        .insert("keybindingRules".into(), json!(rules));
    if !connected(world) {
        return Ok(());
    }
    send_rules(&mut world.mc);
    world.sync()
}

fn add_rule(world: &mut World, key: &str, command: &str, when: &str) -> Outcome {
    let mut rule = json!({"key": key, "command": command});
    if !when.is_empty() {
        rule["when"] = json!(when);
    }
    let mut rules = stored_rules(&mut world.mc);
    rules.push(rule);
    set_rules(world, rules)
}

/// Waits for a save or removal to come back from the MC.
fn settle(world: &mut World) -> Outcome {
    world.wait_for("the keybinding change to settle", |w| {
        !keymap_of(w).saving()
    })?;
    world.sync()
}

fn focus_name(focus: Focus) -> &'static str {
    if focus.terminal {
        "terminal"
    } else if focus.composer {
        "composer"
    } else {
        "window"
    }
}

/// The key and modifiers of a portable sequence ("Ctrl+Alt+G"), as the
/// window is given them.
fn chord(sequence: &str) -> (i32, Modifiers) {
    let mut modifiers = Modifiers::empty();
    let mut code = 0;
    let parts: Vec<&str> = sequence.split('+').collect();
    // "Ctrl++" ends in the key "+".
    let (names, key) = match parts.as_slice() {
        [rest @ .., "", ""] => (rest, "+"),
        [rest @ .., key] => (rest, *key),
        [] => (&[][..], ""),
    };
    for name in names {
        match *name {
            "Ctrl" => modifiers |= Modifiers::CONTROL,
            "Meta" => modifiers |= Modifiers::META,
            "Alt" => modifiers |= Modifiers::ALT,
            "Shift" => modifiers |= Modifiers::SHIFT,
            _ => {}
        }
    }
    let named = match key {
        "Space" => qt::KEY_SPACE,
        "Esc" => qt::KEY_ESCAPE,
        "Tab" => qt::KEY_TAB,
        "Backspace" => qt::KEY_BACKSPACE,
        "Return" => qt::KEY_RETURN,
        "Del" => qt::KEY_DELETE,
        "Home" => qt::KEY_HOME,
        "End" => qt::KEY_END,
        "Left" => qt::KEY_LEFT,
        "Up" => qt::KEY_UP,
        "Right" => qt::KEY_RIGHT,
        "Down" => qt::KEY_DOWN,
        "PgUp" => qt::KEY_PAGE_UP,
        "PgDown" => qt::KEY_PAGE_DOWN,
        _ => 0,
    };
    if named != 0 {
        code = named;
    } else if let Some(n) = key.strip_prefix('F').and_then(|n| n.parse::<i32>().ok()) {
        code = qt::KEY_F1 + n - 1;
    } else if key.chars().count() == 1 {
        code = key.chars().next().unwrap_or(' ').to_ascii_uppercase() as i32;
    }
    (code, modifiers)
}

fn press_sequence(world: &mut World, sequence: &str) -> Outcome {
    ensure_shell(world)?;
    let state = keys(world);
    let focus = {
        let mut s = state.borrow_mut();
        s.acted = true;
        s.sequence = sequence.to_owned();
        s.ran.borrow_mut().clear();
        s.picker.clear();
        s.delivered.clear();
        s.focus
    };
    let delivered = |name: &str| state.borrow_mut().delivered = name.to_owned();
    if sequence.is_empty() {
        delivered(focus_name(focus));
        return Ok(());
    }
    // The application sees the key before any shortcut does.
    let (code, modifiers) = chord(sequence);
    let reached = send_key(world, KeyKind::Press, code, modifiers, false)?;
    send_key(world, KeyKind::Release, code, modifiers, false)?;
    if !reached {
        delivered("application");
        return Ok(());
    }
    let keymap = keymap_of(world);
    let (picker_open, mac) = {
        let s = state.borrow();
        (s.picker_open, s.mac)
    };
    if picker_open {
        let context: Context = [("modelPickerOpen", true), ("isDesktop", true)]
            .into_iter()
            .map(|(k, v)| (k.to_owned(), v))
            .collect();
        let command = keymap::resolve(&keymap.bindings(), sequence, &context, mac);
        if command.starts_with("modelPicker.") && command != "modelPicker.toggle" {
            state.borrow_mut().picker = command;
            return Ok(());
        }
    }
    let shortcuts = keymap.shortcuts();
    let Some(shortcut) = shortcuts.iter().find(|s| text(&s["sequence"]) == sequence) else {
        delivered(focus_name(focus));
        return Ok(());
    };
    // As the window enables its shortcuts.
    let field = if focus.terminal {
        "terminal"
    } else if focus.composer {
        "composer"
    } else if focus.editable {
        "editable"
    } else {
        "chrome"
    };
    if shortcut[field] != json!(true) {
        delivered(focus_name(focus));
        return Ok(());
    }
    // A project script runs through the terminal drawer (workspace.runScript).
    let command = keymap.resolve(world.engine(), sequence, focus);
    if keymap.press(world.engine(), sequence, focus) && command.starts_with("script.") {
        state.borrow().ran.borrow_mut().push(command);
    }
    world.sync()
}

/// Sends a key event through the application to a window, as the platform
/// does before any shortcut sees it. False when an application-wide filter
/// (the quit shortcut's) took it, so the window never did.
///
/// The event is offered to the shell's key filters as Ljós's delivery
/// offers it, newest first (the keymap's, then the quit shortcut's),
/// without a window of its own: Ljós asks its filters only on the way into
/// a window, and the shell's would also see its shortcuts.
pub fn send_key(
    world: &mut World,
    kind: KeyKind,
    key: i32,
    modifiers: Modifiers,
    auto_repeat: bool,
) -> Outcome<bool> {
    let mut event = match kind {
        KeyKind::Press => KeyEvent::press(key),
        KeyKind::Release => KeyEvent::release(key),
    }
    .with_modifiers(modifiers);
    if auto_repeat {
        event = event.repeated();
    }
    let engine = world.engine();
    Keymap::of(engine).key_event(engine, key, kind == KeyKind::Press);
    let kept = controller::with::<QuitController, _>(engine, |quit, engine| {
        quit.key_event(engine, &event)
    })
    .unwrap_or(false);
    world.pump()?;
    Ok(!kept)
}

fn palette_open(world: &World) -> bool {
    controller::with::<Palette, _>(world.engine(), |p, _| p.is_open()).unwrap_or(false)
}

fn press(world: &mut World, key: &str) -> Outcome {
    let lower = key.to_lowercase();
    // An open command palette's search field takes mod+1..9 (CommandPalette.qml).
    if let Some(n) = lower
        .strip_prefix("mod+")
        .and_then(|n| n.parse::<i32>().ok())
        .filter(|n| (1..=9).contains(n))
        && palette_open(world)
    {
        world.with::<Palette, _>(|p, engine| p.run(engine, n - 1))?;
        return world.sync();
    }
    // Its field takes Escape (a step back) and Backspace on an empty query
    // (out of a submenu) too.
    if palette_open(world) && key == "Escape" {
        world.with::<Palette, _>(|p, engine| p.back(engine))?;
        return world.sync();
    }
    // And mod+Enter, which adds the folder being browsed.
    if palette_open(world)
        && lower == "mod+enter"
        && world.with::<Palette, _>(|p, _| p.mode() == "browse")?
    {
        world.with::<Palette, _>(|p, engine| p.add_browsed_folder(engine))?;
        return world.sync();
    }
    if palette_open(world)
        && key == "Backspace"
        && world.with::<Palette, _>(|p, _| p.query().is_empty())?
    {
        world.with::<Palette, _>(|p, engine| p.leave_submenu(engine))?;
        return world.sync();
    }
    // Settings, SnapShots' recorder takes every key while it records
    // (SnapShotSettings.qml).
    if at(&world.state("snapShot"), "shortcut.recording") == &json!(true) {
        let event = brick::key_event(key)?;
        return world.dispatch(
            "snapShot.record.key",
            json!({"key": event.key, "modifiers": event.modifiers.bits() as i32}),
        );
    }
    if press_in_composer(world, key)? {
        return Ok(());
    }
    // A brick on screen that takes the scenario's keys gets them as its
    // window does. What it leaves is the window's, as any other key.
    if let Some(shown) = world.part::<Shown>().0
        && shown.takes_keys
    {
        keys(world).borrow_mut().acted = true;
        if shown.press(world, key)? {
            keys(world).borrow().ran.borrow_mut().clear();
            return world.sync();
        }
    }
    let Some(shortcut) = keymap::parse_shortcut(&lower) else {
        fail!("{key} is not a key");
    };
    let mac = keys(world).borrow().mac;
    press_sequence(world, &keymap::sequence(&shortcut, mac))
}

fn ran(state: &Keys, command: &str) -> bool {
    state.ran.borrow().iter().any(|c| c == command) || state.picker == command
}

fn describe_press(state: &Keys) -> String {
    format!(
        "{} with {}: the shell ran {}, the picker {}, the key went to {}",
        state.sequence,
        focus_name(state.focus),
        show(&json!(*state.ran.borrow())),
        if state.picker.is_empty() {
            "nothing"
        } else {
            &state.picker
        },
        if state.delivered.is_empty() {
            "the window"
        } else {
            &state.delivered
        }
    )
}

fn project_row(id: &str, scripts: Value) -> Value {
    json!({
        "id": id,
        "title": id,
        "workspaceRoot": format!("/work/{id}"),
        "createdAt": "2026-09-01T09:00:00Z",
        "updatedAt": "2026-09-01T09:00:00Z",
        "scripts": scripts,
    })
}

fn thread_row(id: &str, project: &str, title: &str) -> Value {
    json!({
        "id": id,
        "projectId": project,
        "title": title,
        "createdAt": "2026-09-23T09:00:00Z",
        "updatedAt": "2026-09-23T09:00:00Z",
    })
}

fn terminals_available(world: &World) -> bool {
    controller::with::<Terminals, _>(world.engine(), |t, _| t.available()).unwrap_or(false)
}

fn terminals_open(world: &World) -> bool {
    controller::with::<Terminals, _>(world.engine(), |t, _| t.is_open()).unwrap_or(false)
}

fn terminal_tabs(world: &World) -> Vec<Tab> {
    controller::with::<Terminals, _>(world.engine(), |t, _| t.tabs()).unwrap_or_default()
}

/// A thread of a project with a `test` script, shown in the window.
fn show_thread(world: &mut World) -> Outcome {
    let state = keys(world);
    if std::mem::replace(&mut state.borrow_mut().thread_shown, true) {
        return Ok(());
    }
    world.mc.projects.insert(
        "p1".into(),
        project_row(
            "p1",
            json!([{"id": "test", "name": "Test", "command": "bun test"}]),
        ),
    );
    world
        .mc
        .threads
        .insert("t1".into(), thread_row("t1", "p1", "One"));
    ensure_shell(world)?;
    world.dispatch("thread.open", json!({"key": "env-a:t1"}))?;
    world.wait_for("the thread's terminal drawer", terminals_available)
}

/// Threads titled as given (ids "t" + title) in projects named by id, as
/// the MC's snapshot has them when the shell connects.
fn add_threads(world: &mut World, threads: &[(&str, &str)]) -> Outcome {
    for (title, project) in threads {
        world
            .mc
            .projects
            .insert((*project).to_owned(), project_row(project, json!([])));
        let id = format!("t{title}");
        world
            .mc
            .threads
            .insert(id.clone(), thread_row(&id, project, title));
    }
    ensure_shell(world)
}

fn thread_key(world: &World) -> String {
    controller::with::<Navigation, _>(world.engine(), |n, _| n.thread_key().to_owned())
        .unwrap_or_default()
}

fn route(world: &World) -> Route {
    controller::with::<Navigation, _>(world.engine(), |n, _| n.route().clone()).unwrap_or_default()
}

fn wait_for_thread(world: &mut World, key: String) -> Outcome {
    let shown = key.clone();
    world.wait_for_with(
        move |w| thread_key(w) == key,
        move |w| format!("{shown}; the window shows {}", show(&w.state("route"))),
    )
}

fn open_thread(world: &mut World, title: &str) -> Outcome {
    let key = format!("{}:t{title}", world.mc.environment_id);
    world.dispatch("thread.open", json!({"key": key}))?;
    wait_for_thread(world, key)
}

/// Settings → Keybindings' rows.
fn rows(world: &World) -> Vec<Json> {
    keymap_of(world).rows()
}

fn row_for(world: &World, command: &str, key: &str) -> Option<Json> {
    rows(world).into_iter().find(|row| {
        text(&row["command"]) == command && (key.is_empty() || text(&row["key"]) == key)
    })
}

fn describe_rows(world: &World, command: &str) -> String {
    let lines: Vec<String> = rows(world)
        .iter()
        .filter(|row| text(&row["command"]) == command)
        .map(|row| {
            format!(
                "{} when {} ({})",
                text(&row["key"]),
                text(&row["when"]),
                text(&row["source"])
            )
        })
        .collect();
    if lines.is_empty() {
        "no binding".into()
    } else {
        lines.join(", ")
    }
}

fn set_mac(world: &mut World, mac: bool) -> Outcome {
    ensure_shell(world)?;
    keys(world).borrow_mut().mac = mac;
    keymap_of(world).set_mac(world.engine(), mac);
    Ok(())
}

/// The keyboard's modifier as keybindings.json spells it on the platform.
fn modifier_token(mac: bool, physical: &str) -> &'static str {
    match physical {
        "Command" => "mod",
        "Control" => "ctrl",
        "Super" => "meta",
        // Ctrl
        _ if mac => "ctrl",
        _ => "mod",
    }
}

fn qt_modifier(mac: bool, physical: &str) -> i32 {
    // Qt's Control is Command on macOS, and its Meta is Control there.
    match physical {
        "Command" => qt::CONTROL,
        "Control" if mac => qt::META,
        "Control" => qt::CONTROL,
        "Super" => qt::META,
        // Ctrl
        _ if mac => qt::META,
        _ => qt::CONTROL,
    }
}

fn set_focus(world: &mut World, focus: Focus, picker_open: bool) -> Outcome {
    ensure_shell(world)?;
    let state = keys(world);
    let mut s = state.borrow_mut();
    s.focus = focus;
    s.picker_open = picker_open;
    Ok(())
}

const COMPOSER: Focus = Focus {
    terminal: false,
    composer: true,
    editable: true,
};

const TERMINAL: Focus = Focus {
    terminal: true,
    composer: false,
    editable: false,
};

/// The rule as keybindings.json holds it when the command has a default:
/// its condition.
fn default_when(command: &str) -> String {
    keymap::defaults()
        .iter()
        .find(|rule| rule.command == command)
        .and_then(|rule| rule.when.clone())
        .unwrap_or_default()
}

/// QString::localeAwareCompare, near enough for command ids.
fn collated(a: &str, b: &str) -> std::cmp::Ordering {
    a.to_lowercase()
        .cmp(&b.to_lowercase())
        .then_with(|| a.cmp(b))
}

/// The MC's config as it reports the file (apps/server-ex environment.ex:
/// keybindingsConfigPath, issues).
fn report(world: &mut World, issues: Value, editors: Value) -> Outcome {
    let fake = fake_config(&mut world.mc);
    fake.config
        .insert("keybindingsConfigPath".into(), json!(PATH));
    fake.config.insert("issues".into(), issues);
    fake.config.insert("availableEditors".into(), editors);
    if world.shell_subscriptions() == 0 {
        return Ok(());
    }
    // Connected already: the MC sends its config again.
    let fake = fake_config(&mut world.mc);
    let mut config = fake.config.clone();
    config.insert("settings".into(), Value::Object(fake.settings.clone()));
    let mc = &world.mc;
    for id in mc.subscribers("config") {
        if text(&mc.shape_of(id)["environment"]) != mc.environment_id {
            continue;
        }
        mc.send(&json!({"t": "config", "id": id, "mc": mc.name, "config": config}));
    }
    world.sync()
}

fn toast_descriptions(world: &World) -> Vec<String> {
    at(&world.state("toasts"), "items")
        .as_array()
        .map(|items| {
            items
                .iter()
                .map(|item| text(&item["description"]))
                .collect()
        })
        .unwrap_or_default()
}

pub fn register(steps: &mut Steps) {
    steps.extension(|mc| {
        mc.on_rpc("hal-c2.upsertKeybinding", upsert);
        mc.on_rpc("hal-c2.removeKeybinding", remove);
    });

    // Where the keyboard is.
    steps.step(
        "the user is (anywhere|outside a terminal|in a terminal|with the model picker open)",
        |world, c, _| {
            let focus = if c[0] == "in a terminal" {
                TERMINAL
            } else {
                Focus::default()
            };
            set_focus(world, focus, c[0] == "with the model picker open")
        },
    );
    steps.step(
        "(?:the native chrome has keyboard focus|the user is in the desktop app|anything|the terminal is closed)",
        |world, _, _| set_focus(world, Focus::default(), false),
    );
    steps.step("the composer has (?:keyboard )?focus", |world, _, _| {
        // As an outcome: the shell handed the composer the keyboard.
        if world.checking {
            expect!(
                !world.actions_of("composer.focus").is_empty(),
                "{}",
                world.describe_brick_actions()
            );
            return Ok(());
        }
        set_focus(world, COMPOSER, false)
    });
    steps.step(
        "a terminal in the thread has keyboard focus",
        |world, _, _| {
            show_thread(world)?;
            world.dispatch("terminal.toggle", json!({}))?;
            world.wait_for("the thread's first terminal", |w| {
                terminals_open(w) && terminal_tabs(w).len() == 1
            })?;
            set_focus(world, TERMINAL, false)
        },
    );
    // The desktop's preview is the right panel's Previews tab (preview.toggle).
    steps.step(
        "the user is looking at a thread in the desktop app",
        |world, _, _| {
            show_thread(world)?;
            set_focus(world, Focus::default(), false)
        },
    );
    fn preview_shown(world: &World) -> bool {
        controller::with::<RightPanel, _>(world.engine(), |panel, _| {
            panel.is_open() && panel.active_tab() == "previews"
        })
        .unwrap_or(false)
    }
    steps.step("the preview is shown", |world, _, _| {
        let pressed = describe_press(&keys(world).borrow());
        expect!(
            preview_shown(world),
            "{pressed}; the panel is {}",
            show(&world.state("panel"))
        );
        Ok(())
    });
    steps.step("the preview is hidden", |world, _, _| {
        let pressed = describe_press(&keys(world).borrow());
        expect!(
            !preview_shown(world),
            "{pressed}; the panel is {}",
            show(&world.state("panel"))
        );
        Ok(())
    });
    steps.step("the user is on (macOS|Linux|Windows)", |world, c, _| {
        set_mac(world, c[0] == "macOS")
    });

    // Threads of their own for the scenarios with no Background.
    steps.step(
        &format!("the user opened thread {Q} and then thread {Q}"),
        |world, c, _| {
            add_threads(world, &[(&c[0], "p1"), (&c[1], "p1")])?;
            open_thread(world, &c[0])?;
            open_thread(world, &c[1])
        },
    );
    steps.step("the user has several projects", |world, _, _| {
        add_threads(world, &[("One", "p1"), ("Two", "p2")])?;
        open_thread(world, "Two")
    });
    steps.step(
        "the thread list shows at least three threads",
        |world, _, _| {
            add_threads(world, &[("One", "p1"), ("Two", "p1"), ("Three", "p1")])?;
            world.wait_for("three threads in the list", |w| {
                sidebar::ordered_keys(w.engine()).len() >= 3
            })
        },
    );
    steps.step("the third thread opens", |world, _, _| {
        let key = sidebar::ordered_keys(world.engine())
            .get(2)
            .cloned()
            .unwrap_or_default();
        wait_for_thread(world, key)
    });
    steps.step("the user goes forward", |world, _, _| {
        Commands::of(world.engine()).run(world.engine(), "navigation.forward");
        world.sync()
    });
    steps.step(&format!("thread {Q} is shown"), |world, c, _| {
        let key = format!("{}:t{}", world.mc.environment_id, c[0]);
        wait_for_thread(world, key)
    });
    steps.step("the user starts a new local thread", |world, _, _| {
        Commands::of(world.engine()).run(world.engine(), "chat.newLocal");
        world.sync()
    });
    steps.step(
        "a new thread starts in the current project without asking",
        |world, _, _| {
            world.sync()?;
            let route = world.state("route");
            let draft = drafts::draft(world.engine(), &text(at(&route, "draftId")));
            expect!(
                draft.is_some_and(|d| d.project_id == "p2"),
                "the window shows {}",
                show(&route)
            );
            expect!(!palette_open(world), "the command palette asked");
            Ok(())
        },
    );

    // Pressing keys.
    steps.step("the user presses ([^ ]+)(?: again)?", |world, c, _| {
        // A feature may quote the chord.
        press(world, &c[0].replace('"', ""))
    });
    steps.step(
        "the user presses (Command|Ctrl|Control|Super) and ([A-Z])",
        |world, c, _| {
            let mac = keys(world).borrow().mac;
            let key = format!("{}+{}", modifier_token(mac, &c[0]), c[1].to_lowercase());
            press(world, &key)
        },
    );

    // What the key did.
    fn expect_ran(world: &mut World, command: &str, runs: bool) -> Outcome {
        let state = keys(world);
        let state = state.borrow();
        expect!(ran(&state, command) == runs, "{}", describe_press(&state));
        Ok(())
    }
    steps.step(&format!("the command {Q} runs"), |world, c, _| {
        expect_ran(world, &c[0], true)
    });
    steps.step(
        &format!("{Q} behaves as it does in the web app"),
        |world, c, _| expect_ran(world, &c[0], true),
    );
    steps.step(&format!("{Q} (runs|does not run)"), |world, c, _| {
        expect_ran(world, &c[0], c[1] == "runs")
    });
    steps.step(
        "the command palette (opens|does not open)",
        |world, c, _| expect_ran(world, "commandPalette.toggle", c[0] == "opens"),
    );
    steps.step("no new thread starts", |world, _, _| {
        let state = keys(world);
        let state = state.borrow();
        expect!(
            !ran(&state, "chat.new") && world.actions_of("thread.new").is_empty(),
            "{}",
            describe_press(&state)
        );
        Ok(())
    });
    steps.step("the (terminal|composer) receives the key", |world, c, _| {
        let state = keys(world);
        let state = state.borrow();
        expect!(state.delivered == c[0], "{}", describe_press(&state));
        Ok(())
    });

    // The thread's terminal.
    steps.step("the thread's terminal is (shown|hidden)", |world, c, _| {
        show_thread(world)?;
        let open = c[0] == "shown";
        world.wait_for(&format!("the terminal drawer to be {}", c[0]), move |w| {
            terminals_open(w) == open
        })
    });
    steps.step(
        "a new terminal opens instead of a new thread",
        |world, _, _| {
            let state = keys(world);
            let shown = state.clone();
            world.wait_for_with(
                |w| terminal_tabs(w).len() == 2,
                move |_| describe_press(&shown.borrow()),
            )?;
            let state = state.borrow();
            expect!(!ran(&state, "chat.new"), "{}", describe_press(&state));
            Ok(())
        },
    );
    steps.step(
        "a second terminal opens (side by side|stacked below)",
        |world, c, _| {
            let stacked = c[0] == "stacked below";
            let state = keys(world);
            world.wait_for_with(
                move |w| {
                    let rows = terminal_tabs(w);
                    rows.len() == 2
                        && rows[0].group == rows[1].group
                        && rows[1].slot == 1
                        && rows[1].vertical == stacked
                },
                move |_| describe_press(&state.borrow()),
            )
        },
    );
    steps.step("the terminal splits", |world, _, _| {
        expect_ran(world, "terminal.split", true)
    });
    steps.step("the diff panel does not toggle", |world, _, _| {
        expect_ran(world, "diff.toggle", false)
    });
    steps.step("the focused terminal closes", |world, _, _| {
        // The chord asks first, as every close of a terminal the user makes
        // (terminal/tabs.feature).
        let state = keys(world);
        let shown = state.clone();
        world.wait_for_with(
            |w| w.state("confirmation").is_object(),
            move |_| describe_press(&shown.borrow()),
        )?;
        let request = at(&world.state("confirmation"), "requestId").clone();
        world.dispatch(
            "confirmation.answer",
            json!({"requestId": request, "accepted": true}),
        )?;
        world.wait_for_with(
            |w| terminal_tabs(w).is_empty() || !terminals_open(w),
            move |_| describe_press(&state.borrow()),
        )
    });
    steps.step(&format!("the project has a script {Q}"), |world, _, _| {
        show_thread(world)
    });
    steps.step(&format!("the {Q} script runs"), |world, _, _| {
        let state = keys(world);
        world.wait_for_with(
            |w| terminals_open(w) && terminal_tabs(w).len() == 1,
            move |_| format!("the script's terminal; {}", describe_press(&state.borrow())),
        )
    });

    // keybindings.json.
    steps.step("no custom keybindings", |world, _, _| {
        set_rules(world, Vec::new())?;
        ensure_shell(world)
    });
    steps.step(
        &format!("the MC adds the rule ([^ ]+) for {Q}"),
        |world, c, _| {
            keys(world).borrow_mut().acted = true;
            add_rule(world, &c[0], &c[1], "")
        },
    );
    steps.step("the MC removes every custom rule", |world, _, _| {
        keys(world).borrow_mut().acted = true;
        set_rules(world, Vec::new())
    });
    steps.step(
        &format!("keybindings.json only rebinds {Q}"),
        |world, c, _| {
            keys(world).borrow_mut().last_command = c[0].clone();
            set_rules(world, Vec::new())?;
            add_rule(world, "mod+alt+n", &c[0], "")
        },
    );
    steps.step(
        &format!("two rules bind ([^ ]+), first to {Q} and then to {Q}"),
        |world, c, _| {
            add_rule(world, &c[0], &c[1], "")?;
            add_rule(world, &c[0], &c[2], "")
        },
    );
    steps.step(
        "keybindings.json has one valid rule and one with an unknown command",
        |world, _, _| {
            add_rule(world, "mod+alt+g", "diff.toggle", "")?;
            add_rule(world, "mod+alt+u", "nothing.known", "")
        },
    );
    steps.step(
        &format!("keybindings.json binds ([^ ]+) to {Q}"),
        |world, c, _| add_rule(world, &c[0], &c[1], ""),
    );
    steps.step(
        &format!("{Q} is bound to ([^ ]+) when {Q}"),
        |world, c, _| add_rule(world, &c[1], &c[0], &c[2]),
    );
    steps.step(
        &format!("a custom binding ([^ ]+) for {Q}"),
        |world, c, _| {
            add_rule(world, &c[0], &c[1], "")?;
            let state = keys(world);
            let mut s = state.borrow_mut();
            s.last_command = c[1].clone();
            s.last_key = c[0].clone();
            Ok(())
        },
    );
    steps.step(&format!("{Q} was rebound to ([^ ]+)"), |world, c, _| {
        add_rule(world, &c[1], &c[0], &default_when(&c[0]))
    });
    steps.step("the client (?:starts|loads keybindings)", |world, _, _| {
        ensure_shell(world)
    });
    // Given before the user acts, a rule in keybindings.json; after, what
    // the settings list shows.
    steps.step(
        &format!("{Q} is bound to ([^ ]+?)(?: again)?"),
        |world, c, _| {
            if !keys(world).borrow().acted {
                return add_rule(world, &c[1], &c[0], "");
            }
            settle(world)?;
            expect!(
                row_for(world, &c[0], &c[1]).is_some(),
                "{}",
                describe_rows(world, &c[0])
            );
            Ok(())
        },
    );
    steps.step(
        "every other command keeps its default shortcut",
        |world, _, _| {
            let rebound = keys(world).borrow().last_command.clone();
            for rule in keymap::defaults() {
                if rule.command == rebound {
                    continue;
                }
                let row = row_for(world, &rule.command, &rule.key);
                expect!(
                    row.is_some_and(|r| text(&r["source"]) == "Default"),
                    "{}: {}",
                    rule.command,
                    describe_rows(world, &rule.command)
                );
            }
            expect!(
                row_for(world, &rebound, "mod+n").is_none(),
                "{}",
                describe_rows(world, &rebound)
            );
            Ok(())
        },
    );
    steps.step("the valid rule applies", |world, _, _| {
        let command = keymap_of(world).resolve(world.engine(), "Ctrl+Alt+G", Focus::default());
        expect!(
            command == "diff.toggle",
            "{}",
            describe_rows(world, "diff.toggle")
        );
        Ok(())
    });
    steps.step("the unknown one is ignored", |world, _, _| {
        let command = keymap_of(world).resolve(world.engine(), "Ctrl+Alt+U", Focus::default());
        expect!(
            row_for(world, "nothing.known", "").is_none() && command.is_empty(),
            "the unknown rule is bound"
        );
        Ok(())
    });
    steps.step(&format!("{Q} has no shortcut"), |world, c, _| {
        ensure_shell(world)?;
        settle(world)?;
        let label = keymap_of(world).shortcut_label(world.engine(), &c[0]);
        expect!(
            label.is_empty() && row_for(world, &c[0], "").is_none(),
            "{}",
            describe_rows(world, &c[0])
        );
        Ok(())
    });
    steps.step(&format!("the user binds {Q} to ([^ ]+)"), |world, c, _| {
        ensure_shell(world)?;
        keymap_of(world).save(world.engine(), &c[0], &c[1], "", None);
        settle(world)
    });

    // Settings → Keybindings.
    steps.step("the user is in Settings → Keybindings", |world, _, _| {
        ensure_shell(world)?;
        world.dispatch("keybindings.open", json!({}))?;
        expect!(
            route(world) == Route::Settings(KEYBINDINGS_SECTION.into()),
            "the window shows {}",
            show(&world.state("route"))
        );
        Ok(())
    });
    steps.step(
        "each command is listed in order with its shortcut and condition",
        |world, _, _| {
            let listed = rows(world);
            for rule in keymap::defaults() {
                let when = rule.when.clone().unwrap_or_default();
                let shown = listed.iter().any(|row| {
                    text(&row["command"]) == rule.command
                        && text(&row["key"]) == rule.key
                        && text(&row["when"]) == when
                        && !text(&row["keyLabel"]).is_empty()
                });
                expect!(
                    shown,
                    "{}: {}",
                    rule.command,
                    describe_rows(world, &rule.command)
                );
            }
            for pair in listed.windows(2) {
                let (previous, next) = (text(&pair[0]["command"]), text(&pair[1]["command"]));
                expect!(
                    collated(&previous, &next) != std::cmp::Ordering::Greater,
                    "{previous} is listed before {next}"
                );
            }
            Ok(())
        },
    );
    steps.step(
        "each binding is marked Default, Custom or Project",
        |world, _, _| {
            for row in rows(world) {
                let source = text(&row["source"]);
                expect!(
                    ["Default", "Custom", "Project"].contains(&source.as_str()),
                    "{}",
                    show(&row)
                );
            }
            Ok(())
        },
    );
    steps.step(
        &format!("the user searches keybindings for {Q}"),
        |world, c, _| {
            keys(world).borrow_mut().query = c[0].clone();
            Ok(())
        },
    );
    steps.step(
        "only bindings whose (command|label|key|condition|source) matches are listed",
        |world, c, _| {
            let query = keys(world).borrow().query.to_lowercase();
            let field = if c[0] == "condition" { "when" } else { &c[0] };
            // KeybindingsSettings lists the rows whose `search` holds the query.
            for row in rows(world) {
                let listed = text(&row["search"]).contains(&query);
                let matches = text(&row[field]).to_lowercase().contains(&query);
                expect!(
                    listed == matches,
                    "{} {} listed",
                    show(&row),
                    if listed { "is" } else { "is not" }
                );
            }
            Ok(())
        },
    );
    steps.step(&format!("{Q} is labelled {Q}"), |_, c, _| {
        let label = keymap::command_label(&c[0]);
        expect!(label == c[1], "{label}");
        Ok(())
    });
    steps.step(
        &format!("the user records ([^ ]+) for {Q}"),
        |world, c, _| {
            let Some(row) = row_for(world, &c[1], "") else {
                fail!("{}", describe_rows(world, &c[1]));
            };
            {
                let state = keys(world);
                let mut s = state.borrow_mut();
                s.acted = true;
                s.last_command = c[1].clone();
                s.last_key = c[0].clone();
            }
            let when = text(&row["when"]);
            keymap_of(world).save(world.engine(), &c[1], &c[0], &when, Some(&row));
            settle(world)
        },
    );
    steps.step("the binding is marked (Default|Custom)", |world, c, _| {
        let command = keys(world).borrow().last_command.clone();
        let row = row_for(world, &command, "");
        expect!(
            row.is_some_and(|r| text(&r["source"]) == c[0]),
            "{}",
            describe_rows(world, &command)
        );
        Ok(())
    });
    steps.step(
        &format!("the user is recording a shortcut for {Q}"),
        |world, c, _| {
            keys(world).borrow_mut().last_command = c[0].clone();
            Ok(())
        },
    );
    steps.step("the user presses Y alone", |world, _, _| {
        let recorded = keymap_of(world).record_key('Y' as i32, 0);
        keys(world).borrow_mut().last_key = recorded;
        Ok(())
    });
    steps.step("nothing is recorded", |world, _, _| {
        let key = keys(world).borrow().last_key.clone();
        expect!(key.is_empty(), "{key}");
        Ok(())
    });
    steps.step(
        "the user records (Command|Control|Ctrl|Super) plus Y",
        |world, c, _| {
            let mac = keys(world).borrow().mac;
            let recorded = keymap_of(world).record_key('Y' as i32, qt_modifier(mac, &c[0]));
            keys(world).borrow_mut().last_key = recorded;
            Ok(())
        },
    );
    steps.step("the recorded shortcut is ([^ ]+)", |world, c, _| {
        let key = keys(world).borrow().last_key.clone();
        expect!(key == c[0], "{key}");
        Ok(())
    });
    steps.step(
        &format!("the user types the condition {Q}"),
        |world, c, _| {
            keys(world).borrow_mut().condition = c[0].clone();
            Ok(())
        },
    );
    steps.step(&format!("{Q} is flagged as unknown"), |world, c, _| {
        let condition = keys(world).borrow().condition.clone();
        let unknown = Keymap::unknown_variables(&condition);
        expect!(unknown.contains(&c[0]), "{}", show(&json!(unknown)));
        Ok(())
    });
    steps.step(
        &format!("the binding says it conflicts with {Q}"),
        |world, c, _| {
            let (command, key) = {
                let state = keys(world);
                let s = state.borrow();
                (s.last_command.clone(), s.last_key.clone())
            };
            let label = keymap::command_label(&c[0]);
            let row = row_for(world, &command, &key);
            let conflicts = row.as_ref().is_some_and(|r| {
                r["conflicts"]
                    .as_array()
                    .is_some_and(|all| all.iter().any(|c| text(c) == label))
            });
            expect!(
                conflicts,
                "{}",
                row.map_or_else(|| describe_rows(world, &command), |r| show(&r))
            );
            Ok(())
        },
    );
    steps.step(
        "the user is told the most recent matching binding wins when both conditions can apply",
        |world, _, _| {
            let (command, key, mac) = {
                let state = keys(world);
                let s = state.borrow();
                (s.last_command.clone(), s.last_key.clone(), s.mac)
            };
            let wins = keymap::parse_shortcut(&key).is_some_and(|shortcut| {
                keymap_of(world).resolve(
                    world.engine(),
                    &keymap::sequence(&shortcut, mac),
                    Focus::default(),
                ) == command
            });
            expect!(wins, "{}", describe_rows(world, &command));
            Ok(())
        },
    );
    steps.step(
        &format!("the user resets {Q} to its default"),
        |world, c, _| {
            {
                let state = keys(world);
                let mut s = state.borrow_mut();
                s.acted = true;
                s.last_command = c[0].clone();
            }
            let row = row_for(world, &c[0], "");
            let Some(row) = row.filter(|r| r["canReset"] == json!(true)) else {
                fail!("{}", describe_rows(world, &c[0]));
            };
            keymap_of(world).reset(world.engine(), &row);
            settle(world)
        },
    );
    steps.step("no default binding offers to be removed", |world, _, _| {
        for row in rows(world) {
            if text(&row["source"]) == "Default" {
                expect!(row["canRemove"] != json!(true), "{}", show(&row));
            }
        }
        Ok(())
    });
    steps.step("the user removes that binding", |world, _, _| {
        let (command, key) = {
            let state = keys(world);
            let mut s = state.borrow_mut();
            s.acted = true;
            (s.last_command.clone(), s.last_key.clone())
        };
        let row = row_for(world, &command, &key);
        let Some(row) = row.filter(|r| r["canRemove"] == json!(true)) else {
            fail!("{}", describe_rows(world, &command));
        };
        keymap_of(world).remove(world.engine(), &row);
        settle(world)
    });
    steps.step(
        &format!("the user adds a keybinding for {Q} with ([^ ]+)"),
        |world, c, _| {
            keys(world).borrow_mut().acted = true;
            keymap_of(world).save(world.engine(), &c[0], &c[1], "", None);
            settle(world)
        },
    );
    steps.step(
        "the environment will reject keybinding changes",
        |world, _, _| {
            for method in ["hal-c2.upsertKeybinding", "hal-c2.removeKeybinding"] {
                world
                    .mc
                    .refusals
                    .insert(method.into(), "Read-only file system".into());
            }
            Ok(())
        },
    );
    steps.step("the user (saves|removes) a binding", |world, c, _| {
        keys(world).borrow_mut().acted = true;
        let keymap = keymap_of(world);
        if c[0] == "saves" {
            keymap.save(
                world.engine(),
                "diff.toggle",
                "mod+shift+y",
                "!terminalFocus",
                None,
            );
        } else {
            keymap.remove(
                world.engine(),
                &json!({"command": "diff.toggle", "key": "mod+shift+y"}),
            );
        }
        settle(world)
    });

    // Settings → Keybindings: the file, conditions typed in full, and saving
    // to every environment (navigation/keybinding-settings.feature,
    // keybinding-customisation.feature).
    steps.step("keybindings.json is not valid JSON", |world, _, _| {
        // The MC keeps no rule of a file it cannot parse, and says why.
        fake_config(&mut world.mc)
            .config
            .insert("keybindingRules".into(), json!([]));
        report(
            world,
            json!([{
                "kind": "keybindings.malformed-config",
                "message": format!("Unable to parse keybindings config at {PATH}: expected JSON array"),
            }]),
            json!(["zed"]),
        )
    });
    steps.step("the default shortcuts apply", |world, _, _| {
        for rule in keymap::defaults() {
            let row = row_for(world, &rule.command, &rule.key);
            expect!(
                row.is_some_and(|r| text(&r["source"]) == "Default"),
                "{}: {}",
                rule.command,
                describe_rows(world, &rule.command)
            );
        }
        let mac = keys(world).borrow().mac;
        let sequence = keymap::parse_shortcut("mod+k")
            .map(|s| keymap::sequence(&s, mac))
            .unwrap_or_default();
        let command = keymap_of(world).resolve(world.engine(), &sequence, Focus::default());
        expect!(
            command == "commandPalette.toggle",
            "{}",
            describe_rows(world, "commandPalette.toggle")
        );
        Ok(())
    });
    steps.step(
        &format!("the user is told {Q} with the file path"),
        |world, c, _| {
            let told = c[0].clone();
            let shown = c[0].clone();
            world.wait_for_with(
                move |w| {
                    toast_descriptions(w)
                        .iter()
                        .any(|d| d.starts_with(&told) && d.contains(PATH))
                },
                move |w| {
                    format!(
                        "\"{shown}\" with {PATH}; the toasts are {}",
                        show(&w.state("toasts"))
                    )
                },
            )
        },
    );
    steps.step("no editor is available", |world, _, _| {
        report(world, json!([]), json!([]))?;
        keys(world).borrow_mut().condition = "no editors".into();
        Ok(())
    });
    steps.step(
        "the user opens keybindings.json from settings",
        |world, _, _| {
            ensure_shell(world)?;
            let no_editors =
                std::mem::take(&mut keys(world).borrow_mut().condition) == "no editors";
            if !no_editors {
                report(world, json!([]), json!(["cursor", "zed"]))?;
            }
            world.wait_for("the MC to say where keybindings.json is", |w| {
                !keymap_of(w).file_path().is_empty()
            })?;
            // The editor the user opened last.
            Settings::of(world.engine()).write_device(world.engine(), "lastEditor", json!("zed"));
            world.dispatch("keybindings.open", json!({}))?;
            keymap_of(world).open_file(world.engine());
            world.sync()
        },
    );
    steps.step(
        "keybindings.json opens in the user's preferred editor",
        |world, _, _| {
            let opened: Vec<Value> = world
                .mc
                .calls
                .iter()
                .filter(|rpc| rpc.method == "shell.openInEditor")
                .map(|rpc| rpc.payload.clone())
                .collect();
            expect!(
                opened.len() == 1
                    && text(&opened[0]["cwd"]) == PATH
                    && text(&opened[0]["editor"]) == "zed",
                "the MC was asked to open {}",
                show(&json!(opened))
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user adds the condition {Q}, negates it, and groups it with {Q}"),
        |world, c, _| {
            ensure_shell(world)?;
            // The desktop's condition is one field: what a condition builder
            // assembles, typed.
            let condition = format!("!{} && {}", c[0], c[1]);
            let (error, unknown) = (
                Keymap::when_error(&condition),
                Keymap::unknown_variables(&condition),
            );
            expect!(
                error.is_empty() && unknown.is_empty(),
                "{condition}: {error} {}",
                show(&json!(unknown))
            );
            let (command, key) = ("diff.toggle".to_owned(), "mod+shift+y".to_owned());
            {
                let state = keys(world);
                let mut s = state.borrow_mut();
                s.acted = true;
                s.last_command = command.clone();
                s.last_key = key.clone();
            }
            keymap_of(world).save(world.engine(), &command, &key, &condition, None);
            settle(world)
        },
    );
    steps.step(&format!("the binding's condition is {Q}"), |world, c, _| {
        let (command, key, mac) = {
            let state = keys(world);
            let s = state.borrow();
            (s.last_command.clone(), s.last_key.clone(), s.mac)
        };
        let row = row_for(world, &command, &key);
        expect!(
            row.is_some_and(|r| text(&r["when"]) == c[0]),
            "{}",
            describe_rows(world, &command)
        );
        // And the keymap honours it: the key runs the command only where it
        // holds.
        let sequence = keymap::parse_shortcut(&key)
            .map(|s| keymap::sequence(&s, mac))
            .unwrap_or_default();
        let keymap = keymap_of(world);
        let (in_terminal, anywhere) = (
            keymap.resolve(world.engine(), &sequence, TERMINAL),
            keymap.resolve(world.engine(), &sequence, Focus::default()),
        );
        expect!(
            in_terminal.is_empty() && anywhere.is_empty(),
            "the key runs {anywhere} without the condition"
        );
        Ok(())
    });
    steps.step("two environments are connected", |world, _, _| {
        if crate::steps::composer_workspace::connect_second_composer_environment(world)? {
            return Ok(());
        }
        ensure_shell(world)?;
        world.mc.join("mc-b", "env-b");
        world.sync()?;
        world.wait_for("the second environment", |w| {
            store::with(w.engine(), |s| s.environment_online("env-b"))
        })
    });
    steps.step(&format!("the user rebinds {Q}"), |world, c, _| {
        let Some(row) = row_for(world, &c[0], "") else {
            fail!("{}", describe_rows(world, &c[0]));
        };
        let key = "mod+shift+y".to_owned();
        {
            let state = keys(world);
            let mut s = state.borrow_mut();
            s.acted = true;
            s.last_command = c[0].clone();
            s.last_key = key.clone();
        }
        let when = text(&row["when"]);
        keymap_of(world).save(world.engine(), &c[0], &key, &when, Some(&row));
        settle(world)
    });
    steps.step("both environments store the new binding", |world, _, _| {
        let (command, key) = {
            let state = keys(world);
            let s = state.borrow();
            (s.last_command.clone(), s.last_key.clone())
        };
        let stores = |rules: &[Value]| {
            rules
                .iter()
                .any(|rule| text(&rule["command"]) == command && text(&rule["key"]) == key)
        };
        let here = stored_rules(&mut world.mc);
        let there = world
            .mc
            .part::<Elsewhere>()
            .0
            .get("env-b")
            .cloned()
            .unwrap_or_default();
        expect!(
            stores(&here) && stores(&there),
            "this environment stores {}, the other {}",
            show(&json!(here)),
            show(&json!(there))
        );
        Ok(())
    });
}

/// What Settings → Keybindings says is wrong with the condition the user
/// typed (empty when nothing is), for "the user is told".
pub fn condition_problem(world: &mut World) -> String {
    let typed = keys(world).borrow().condition.clone();
    if typed.is_empty() {
        String::new()
    } else {
        Keymap::when_error(&typed)
    }
}

/// Where the keyboard is for the scenario's next key presses (all false:
/// the native chrome), connecting the shell first.
pub fn set_key_focus(world: &mut World, focus: Focus) -> Outcome {
    set_focus(world, focus, false)
}

/// Presses a key as keybindings.json spells it ("mod+z"), as "the user
/// presses" does.
pub fn press_key(world: &mut World, key: &str) -> Outcome {
    press(world, key)
}

/// Whether the last press ran `command`.
pub fn key_ran(world: &mut World, command: &str) -> bool {
    ran(&keys(world).borrow(), command)
}

/// What the last press did, for a failure.
pub fn describe_key_press(world: &mut World) -> String {
    describe_press(&keys(world).borrow())
}

/// What received the last key the window did not take ("composer",
/// "terminal", "window", "application").
pub fn key_delivered_to(world: &mut World) -> String {
    keys(world).borrow().delivered.clone()
}
