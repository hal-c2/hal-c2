//! `mobileTerminal`, mobile-qt's MobileTerminal: what the phone's
//! terminal screen adds to the desktop's TerminalController (the
//! shell's [`Terminals`]), which keeps the terminals: the key row's
//! held modifier and paste, the text size, the terminal menu's
//! rows, and picking visible lines for the draft.
//!
//! Publishes `mobileTerminal`:
//!   {terminal:  the label of the terminal shown,
//!    label:     its state in a word,
//!    modifiers: the row's modifier keys,
//!    held:      the modifier waiting for a key, "" for none,
//!    textSize:  points,
//!    context:   {lines, start, end, tooLarge} while choosing lines, or null}
//!
//! Actions: `mobileTerminal.input {data}`, `mobileTerminal.modifier
//! {key}`, `mobileTerminal.paste`, `mobileTerminal.clear`,
//! `mobileTerminal.textSize {points}`, `mobileTerminal.covered
//! {covered}`, `mobileTerminal.menu {x, y, lines}`,
//! `mobileTerminal.context.open {lines}`, `.tap {index}`, `.attach` and
//! `.cancel`.
//!

use std::cell::RefCell;
use std::path::PathBuf;

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controller::{self, Controller, Init, Me};
use hal_c2_shell::controllers::menus::{Item, Menus};
use hal_c2_shell::controllers::terminals::{ListedTerminal, Terminals};
use hal_c2_shell::controllers::toasts::Toasts;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::Mc;
use hal_c2_shell::store;
use ljos::prelude::Engine;
use serde_json::json;

const KEY: &str = "mobileTerminal";

pub const DEFAULT_TEXT_SIZE: f64 = 10.5;
pub const MIN_TEXT_SIZE: f64 = 6.0;
pub const MAX_TEXT_SIZE: f64 = 14.0;
/// COMPOSER_CONTEXT_MAX_RECORDS and _TERMINAL_TEXT_MAX_CHARS of
/// packages/contracts, in UTF-16 units as the contract counts.
pub const MAX_CONTEXT_ITEMS: usize = 200;
pub const MAX_CONTEXT_CHARS: usize = 64_000;
pub const TEXT_SIZE_STEP: f64 = 0.5;

fn units(text: &str) -> usize {
    text.encode_utf16().count()
}

/// What Control-<first character> is: a-z, @ and [\]^_? by their control
/// codes, anything else as it is (upstream T3 Code's accessory row).
pub fn with_control(data: &str) -> String {
    let Some(first) = data.chars().next() else {
        return data.to_owned();
    };
    let lower = first.to_ascii_lowercase();
    let code = match lower {
        'a'..='z' => lower as u32 - 96,
        '@' => 0,
        '[' => 0x1b,
        '\\' => 0x1c,
        ']' => 0x1d,
        '^' => 0x1e,
        '_' => 0x1f,
        '?' => 0x7f,
        _ => return data.to_owned(),
    };
    char::from_u32(code)
        .map(|c| c.to_string())
        .unwrap_or_else(|| data.to_owned())
}

/// A pasted text as a shell should get it, with no bracketed-paste
/// markers: lines separated by Return, tabs kept, any other control
/// character a space.
pub fn for_paste(text: &str) -> String {
    let cleaned: String = text
        .chars()
        .map(|c| {
            let n = c as u32;
            if n <= 0x8 || n == 0xb || n == 0xc || (0xe..=0x1f).contains(&n) || n == 0x7f {
                ' '
            } else {
                c
            }
        })
        .collect();
    cleaned.replace("\r\n", "\r").replace('\n', "\r")
}

/// A terminal's state in a word, from its MC summary's `status` and
/// whether a task runs in it; no status is a terminal not started.
pub fn status_label(status: &str, busy: bool) -> &'static str {
    match status {
        "running" if busy => "Task running",
        "running" => "Ready",
        "starting" => "Starting",
        "exited" => "Exited",
        "error" => "Error",
        _ => "Not started",
    }
}

/// The last folder of a path.
pub fn folder_name(path: &str) -> String {
    std::path::Path::new(path.trim_end_matches('/'))
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// The draft's label for output attached from the terminal `name`. The
/// name is empty until the Terminals listing is ported (H1), so the
/// context reads as a terminal's, not as " (visible output)".
pub fn context_label(name: &str) -> String {
    let name = if name.is_empty() { "Terminal" } else { name };
    format!("{name} (visible output)")
}

/// An arrow key as a terminal sends it, ESC [ A..D or, in application
/// cursor mode, ESC O A..D: its letter, else none.
fn arrow_of(data: &str) -> Option<char> {
    let mut chars = data.chars();
    if chars.next()? != '\u{1b}' || !matches!(chars.next()?, '[' | 'O') {
        return None;
    }
    let letter = chars.next()?;
    (('A'..='D').contains(&letter) && chars.next().is_none()).then_some(letter)
}

fn one_character(data: &str) -> bool {
    units(data) == 1 || (units(data) == 2 && data.chars().count() == 1)
}

/// What a held modifier makes of `data`: the keys to write, or a paste
/// (the host's paste chord). `held` is spent either way.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HeldInput {
    Write(String),
    Paste,
}

pub fn apply_held(held: &str, data: &str, darwin: bool) -> HeldInput {
    let paste_with = if darwin { "cmd" } else { "ctrl" };
    if let Some(arrow) = arrow_of(data) {
        // An arrow with Control (5) or Meta (3), as xterm sends it.
        return HeldInput::Write(format!(
            "\u{1b}[1;{}{arrow}",
            if held == "ctrl" { 5 } else { 3 }
        ));
    }
    if held == paste_with && data.eq_ignore_ascii_case("v") {
        return HeldInput::Paste;
    }
    if held == "ctrl" {
        return HeldInput::Write(with_control(data));
    }
    // Alt, and cmd on a Mac (whose row has no Option key), are Meta.
    HeldInput::Write(format!("\u{1b}{data}"))
}

/// Picking visible lines for the draft: two taps bound them.
#[derive(Clone, Debug, Default)]
pub struct Context {
    pub lines: Vec<String>,
    pub start: usize,
    pub end: usize,
    /// The first of two taps, if one is down.
    anchor: Option<usize>,
}

impl Context {
    /// The lines to choose from, trailing blank ones off; none is
    /// nothing to choose.
    pub fn open(lines: Vec<String>) -> Option<Context> {
        let mut lines = lines;
        while lines.last().is_some_and(|line| line.trim().is_empty()) {
            lines.pop();
        }
        if lines.is_empty() {
            return None;
        }
        let end = lines.len() - 1;
        Some(Context {
            lines,
            start: 0,
            end,
            anchor: None,
        })
    }

    pub fn tap(&mut self, index: usize) {
        if index >= self.lines.len() {
            return;
        }
        match self.anchor {
            None => {
                self.anchor = Some(index);
                self.start = index;
                self.end = index;
            }
            Some(anchor) => {
                self.start = anchor.min(index);
                self.end = anchor.max(index);
                self.anchor = None;
            }
        }
    }

    pub fn text(&self) -> String {
        self.lines[self.start..=self.end].join("\n")
    }

    pub fn too_large(&self) -> bool {
        units(&self.text()) > MAX_CONTEXT_CHARS
    }

    fn state(&self) -> Json {
        json!({
            "lines": self.lines,
            "start": self.start,
            "end": self.end,
            "tooLarge": self.too_large(),
        })
    }
}

/// Where the text size is kept (`<config>/terminal.json`).
#[derive(Default)]
struct Where {
    store_path: RefCell<Option<PathBuf>>,
}

/// Says where the text size is kept. Before start.
pub fn set_store_path(engine: &Engine, path: Option<PathBuf>) {
    *engine.extension::<Where>().store_path.borrow_mut() = path;
}

pub struct MobileTerminal {
    bridge: Bridge,
    me: Me<MobileTerminal>,
    mc: std::rc::Rc<dyn Mc>,
    store_path: Option<PathBuf>,
    held: String,
    held_for: String,
    text_size: f64,
    choosing: Option<Context>,
    /// The terminal the chosen lines are from: its id and label.
    context_terminal: (String, String),
}

impl Controller for MobileTerminal {
    fn new(init: Init<'_, Self>) -> Self {
        let store_path = init.engine.extension::<Where>().store_path.borrow().clone();
        let mut text_size = DEFAULT_TEXT_SIZE;
        if let Some(path) = &store_path
            && let Ok(bytes) = std::fs::read(path)
            && let Ok(saved) = serde_json::from_slice::<Json>(&bytes)
            && let Some(stored) = saved.get("textSize").and_then(Json::as_f64)
        {
            text_size = stored.clamp(MIN_TEXT_SIZE, MAX_TEXT_SIZE);
        }
        hal_c2_shell::controllers::terminals::on_changed(init.engine, {
            let me = init.me.clone();
            move |engine| {
                me.run(engine, |c: &mut MobileTerminal, engine| c.publish(engine));
            }
        });
        MobileTerminal {
            bridge: init.bridge,
            me: init.me,
            mc: init.mc,
            store_path,
            held: String::new(),
            held_for: String::new(),
            text_size,
            choosing: None,
            context_terminal: (String::new(), String::new()),
        }
    }

    fn activate(&mut self, engine: &Engine) {
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !action.starts_with("mobileTerminal.") {
            return false;
        }
        let text = |key: &str| {
            payload
                .get(key)
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        match action {
            "mobileTerminal.input" => self.input(engine, &text("data")),
            "mobileTerminal.modifier" => {
                let key = text("key");
                self.held = if self.held == key { String::new() } else { key };
                self.held_for = self.shown_id(engine);
                self.publish(engine);
            }
            "mobileTerminal.paste" => self.paste(engine),
            "mobileTerminal.clear" => self.clear(engine),
            "mobileTerminal.covered" => {
                let covered = payload
                    .get("covered")
                    .and_then(Json::as_bool)
                    .unwrap_or(false);
                controller::with::<Terminals, _>(engine, |terminals, engine| {
                    terminals.set_covered(engine, covered);
                });
            }
            "mobileTerminal.textSize" => {
                let points = payload
                    .get("points")
                    .and_then(Json::as_f64)
                    .unwrap_or(self.text_size);
                self.set_text_size(engine, points);
            }
            "mobileTerminal.menu" => self.open_menu(engine, payload),
            "mobileTerminal.context.open" => {
                let lines = payload
                    .get("lines")
                    .and_then(Json::as_array)
                    .map(|lines| {
                        lines
                            .iter()
                            .map(|line| line.as_str().unwrap_or_default().to_owned())
                            .collect()
                    })
                    .unwrap_or_default();
                self.open_context(engine, lines);
            }
            "mobileTerminal.context.tap" => {
                let index = payload.get("index").and_then(Json::as_i64).unwrap_or(-1);
                if let (Some(context), Ok(index)) = (&mut self.choosing, usize::try_from(index)) {
                    context.tap(index);
                }
                self.publish(engine);
            }
            "mobileTerminal.context.attach" => self.attach_context(engine),
            "mobileTerminal.context.cancel" => {
                self.choosing = None;
                self.publish(engine);
            }
            _ => return false,
        }
        true
    }
}

impl MobileTerminal {
    fn write(&self, engine: &Engine, data: &str) {
        let data = data.to_owned();
        controller::with::<Terminals, _>(engine, |terminals, engine| {
            let id = terminals.active_terminal_id();
            if let Some(session) = terminals.session(&id) {
                session.write(engine, &data);
            }
        });
    }

    fn has_session(&self, engine: &Engine) -> bool {
        controller::with::<Terminals, _>(engine, |terminals, _| {
            let id = terminals.active_terminal_id();
            terminals.session(&id).is_some()
        })
        .unwrap_or(false)
    }

    /// The terminal menu's rows, as the C++ builds them in openMenu.
    pub fn menu_items(
        listing: &[ListedTerminal],
        active: &str,
        open: bool,
        root: &str,
        scripts: &[Json],
        text_size: f64,
    ) -> Vec<Item> {
        let mut items: Vec<Item> = Vec::new();
        let mut terminals_group = Item::new("terminals", "Terminals");
        for listed in listing {
            let ended = matches!(listed.status.as_str(), "exited" | "error");
            if ended && listed.terminal_id != active {
                continue;
            }
            let mut row = Item::new(
                format!("terminal:{}", listed.terminal_id),
                listed.label.clone(),
            );
            row.icon = "terminal".into();
            row.checked = listed.terminal_id == active && open;
            row.subtitle = format!(
                "{} · {}",
                status_label(&listed.status, listed.busy),
                if listed.cwd.is_empty() {
                    root.to_owned()
                } else {
                    folder_name(&listed.cwd)
                }
            );
            terminals_group.children.push(row);
        }
        if !terminals_group.children.is_empty() {
            items.push(terminals_group);
        }
        let mut fresh = Item::new("new", "Open new terminal");
        fresh.icon = "plus".into();
        fresh.subtitle = format!(
            "Start another shell in {}",
            if root.is_empty() {
                "this workspace"
            } else {
                &root
            }
        );
        items.push(fresh);
        let mut scripts_group = Item::new("scripts", "Scripts");
        for script in scripts {
            let name = script
                .get("name")
                .and_then(Json::as_str)
                .unwrap_or_default();
            let setup = script
                .get("runOnWorktreeCreate")
                .and_then(Json::as_bool)
                .unwrap_or(false);
            let mut row = Item::new(
                format!(
                    "script:{}",
                    script.get("id").and_then(Json::as_str).unwrap_or_default()
                ),
                if setup {
                    format!("{name} (setup)")
                } else {
                    name.to_owned()
                },
            );
            row.icon = "play".into();
            row.subtitle = script
                .get("command")
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned();
            scripts_group.children.push(row);
        }
        if scripts_group.children.is_empty() {
            let mut none = Item::new("no-scripts", "This project has no saved scripts yet");
            none.enabled = false;
            scripts_group.children.push(none);
        }
        items.push(scripts_group);
        if open {
            let mut context = Item::new("context", "Add visible lines to the message");
            context.icon = "message-square-plus".into();
            items.push(context);
            let mut smaller = Item::new("smaller", format!("Smaller text ({:.1} pt)", text_size));
            smaller.icon = "minus".into();
            smaller.enabled = text_size > MIN_TEXT_SIZE;
            items.push(smaller);
            let mut larger = Item::new("larger", format!("Larger text ({:.1} pt)", text_size));
            larger.icon = "plus".into();
            larger.enabled = text_size < MAX_TEXT_SIZE;
            items.push(larger);
            let mut close = Item::new("close", "Close terminal");
            close.icon = "x".into();
            close.destructive = true;
            items.push(close);
        }
        items
    }

    fn shown_id(&self, engine: &Engine) -> String {
        controller::with::<Terminals, _>(engine, |terminals, _| {
            let active = terminals.active_terminal_id();
            if !active.is_empty() {
                return active;
            }
            terminals
                .listing()
                .first()
                .map(|listed| listed.terminal_id.clone())
                .unwrap_or_default()
        })
        .unwrap_or_default()
    }

    fn shown(&self, engine: &Engine) -> Option<ListedTerminal> {
        let id = self.shown_id(engine);
        controller::with::<Terminals, _>(engine, |terminals, _| {
            terminals
                .listing()
                .into_iter()
                .find(|listed| listed.terminal_id == id)
        })
        .flatten()
    }

    /// "darwin", "linux", "windows" or "" for the thread's environment.
    fn host_system(&self, engine: &Engine) -> String {
        let place =
            controller::with::<Terminals, _>(engine, |terminals, _| terminals.place().cloned())
                .flatten();
        let Some(place) = place else {
            return String::new();
        };
        let os = store::with(engine, |store| {
            store
                .environment(&place.environment_id)
                .get("platform")
                .and_then(Json::as_object)
                .and_then(|platform| platform.get("os"))
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned()
        });
        if !os.is_empty() {
            return os;
        }
        self.mc
            .status()
            .descriptor
            .get("platform")
            .and_then(Json::as_object)
            .and_then(|platform| platform.get("os"))
            .and_then(Json::as_str)
            .unwrap_or_default()
            .to_owned()
    }

    fn clear(&mut self, engine: &Engine) {
        // The key row's clear releases a held modifier either way.
        self.held.clear();
        let place = controller::with::<Terminals, _>(engine, |terminals, _| {
            let id = terminals.active_terminal_id();
            let has = terminals.session(&id).is_some();
            (has, terminals.place().cloned(), id)
        });
        let Some((true, Some(place), active)) = place else {
            // The release is shown at once, even with no live
            // session to clear.
            self.publish(engine);
            return;
        };
        self.publish(engine);
        self.mc.call(
            &place.environment_id,
            "terminal.clear",
            json!({"threadId": place.thread_id, "terminalId": active}),
            Box::new(|_, _| {}),
        );
    }

    fn open_menu(&mut self, engine: &Engine, payload: &Json) {
        let (place, listing, active, open) =
            match controller::with::<Terminals, _>(engine, |terminals, _| {
                (
                    terminals.place().cloned(),
                    terminals.listing(),
                    terminals.active_terminal_id(),
                    terminals.is_open(),
                )
            }) {
                Some(parts) => parts,
                None => return,
            };
        let Some(place) = place else {
            return;
        };
        let root = folder_name(&place.cwd);
        let visible: Vec<String> = payload
            .get("lines")
            .and_then(Json::as_array)
            .map(|lines| {
                lines
                    .iter()
                    .map(|line| line.as_str().unwrap_or_default().to_owned())
                    .collect()
            })
            .unwrap_or_default();
        let items = Self::menu_items(
            &listing,
            &active,
            open,
            &root,
            &place.scripts,
            self.text_size,
        );
        let x = payload.get("x").and_then(Json::as_f64).unwrap_or_default();
        let y = payload.get("y").and_then(Json::as_f64).unwrap_or_default();
        let me = self.me.clone();
        // The lines are the shown terminal's: its identity is
        // captured with them, as settling may move on meanwhile.
        let shown = self
            .shown(engine)
            .map(|shown| (shown.terminal_id, shown.label))
            .unwrap_or_default();
        controller::with::<Menus, _>(engine, |menus, engine| {
            menus.open(engine, x, y, items, move |engine, id| {
                let (id, visible, shown) = (id.to_owned(), visible.clone(), shown.clone());
                me.run(engine, move |c: &mut MobileTerminal, engine| {
                    c.menu_chosen(engine, &id, visible, shown);
                });
            });
        });
    }

    fn menu_chosen(
        &mut self,
        engine: &Engine,
        id: &str,
        visible: Vec<String>,
        shown: (String, String),
    ) {
        if let Some(terminal_id) = id.strip_prefix("terminal:") {
            self.bridge.dispatch(
                engine,
                "terminal.select",
                json!({"terminalId": terminal_id}),
            );
        } else if id == "new" {
            self.bridge.dispatch(engine, "terminal.new", Json::Null);
        } else if let Some(script_id) = id.strip_prefix("script:") {
            let script_id = script_id.to_owned();
            controller::with::<Terminals, _>(engine, |terminals, engine| {
                terminals.run_script(engine, &script_id);
            });
        } else if id == "context" {
            self.open_context_captured(engine, visible, shown);
        } else if id == "smaller" {
            self.set_text_size(engine, self.text_size - TEXT_SIZE_STEP);
        } else if id == "larger" {
            self.set_text_size(engine, self.text_size + TEXT_SIZE_STEP);
        } else if id == "close" {
            self.bridge.dispatch(engine, "terminal.close", Json::Null);
        }
    }

    fn input(&mut self, engine: &Engine, data: &str) {
        // An ended shell has no session: what is typed goes nowhere.
        if !self.has_session(engine) {
            return;
        }
        // A modifier held in another terminal is not this one's.
        if !self.held.is_empty() && self.held_for != self.shown_id(engine) {
            self.held.clear();
            self.publish(engine);
        }
        if self.held.is_empty() || (!one_character(data) && arrow_of(data).is_none()) {
            self.write(engine, data);
            return;
        }
        let held = std::mem::take(&mut self.held);
        self.publish(engine);
        match apply_held(&held, data, self.host_system(engine) == "darwin") {
            HeldInput::Write(keys) => self.write(engine, &keys),
            HeldInput::Paste => self.paste(engine),
        }
    }

    fn paste(&self, engine: &Engine) {
        if !self.has_session(engine) {
            return;
        }
        let text = ljos::prelude::Platform::of(engine)
            .clipboard()
            .text(ljos::prelude::ClipboardMode::Clipboard)
            .unwrap_or_default();
        if !text.is_empty() {
            self.write(engine, &for_paste(&text));
        }
    }

    fn set_text_size(&mut self, engine: &Engine, size: f64) {
        self.text_size = size.clamp(MIN_TEXT_SIZE, MAX_TEXT_SIZE);
        self.publish(engine);
        if let Some(path) = &self.store_path {
            if let Some(dir) = path.parent() {
                let _ = std::fs::create_dir_all(dir);
            }
            let saved = json!({"textSize": self.text_size});
            let _ = std::fs::write(path, saved.to_string());
        }
    }

    fn open_context(&mut self, engine: &Engine, lines: Vec<String>) {
        let shown = self
            .shown(engine)
            .map(|shown| (shown.terminal_id, shown.label))
            .unwrap_or_default();
        self.open_context_captured(engine, lines, shown);
    }

    fn open_context_captured(
        &mut self,
        engine: &Engine,
        lines: Vec<String>,
        shown: (String, String),
    ) {
        let toast = |engine: &Engine, title: &str, description: &str| {
            let (title, description) = (title.to_owned(), description.to_owned());
            controller::with::<Toasts, _>(engine, |toasts, engine| {
                toasts.show(engine, "error", &title, &description, None, 0);
            });
        };
        let Some(context) = Context::open(lines) else {
            toast(
                engine,
                "No terminal output",
                "There is no visible output to attach.",
            );
            return;
        };
        let contexts = self
            .bridge
            .published(engine, "composer")
            .and_then(|composer| composer.get("terminalContexts").cloned())
            .and_then(|held| held.as_array().map(|held| held.len()))
            .unwrap_or(0);
        if contexts >= MAX_CONTEXT_ITEMS {
            toast(
                engine,
                "Too many context items",
                "Remove some context from the draft and try again.",
            );
            return;
        }
        self.context_terminal = shown;
        self.choosing = Some(context);
        self.publish(engine);
    }

    fn attach_context(&mut self, engine: &Engine) {
        let Some(context) = &self.choosing else {
            return;
        };
        let text = context.text();
        if text.trim().is_empty() || units(&text) > MAX_CONTEXT_CHARS {
            return;
        }
        let payload = json!({
            "terminalId": self.context_terminal.0,
            "terminalLabel": context_label(&self.context_terminal.1),
            "lineStart": context.start + 1,
            "lineEnd": context.end + 1,
            "text": text,
        });
        self.choosing = None;
        self.publish(engine);
        self.bridge
            .dispatch(engine, "composer.terminalContext.add", payload);
        // Back at the thread, where the draft is. Dispatched from a
        // controller, it runs after this one returns.
        let open = controller::with::<Terminals, _>(engine, |terminals, _| terminals.is_open())
            .unwrap_or(false);
        if open {
            self.bridge.dispatch(engine, "terminal.toggle", Json::Null);
        }
    }

    fn publish(&mut self, engine: &Engine) {
        // A modifier is held for the terminal it was pressed in.
        if !self.held.is_empty() && self.held_for != self.shown_id(engine) {
            self.held.clear();
        }
        let shown = self.shown(engine);
        let darwin = self.host_system(engine) == "darwin";
        self.bridge.publish(
            engine,
            KEY,
            json!({
                "label": shown.as_ref().map_or_else(
                    || status_label("", false),
                    |shown| status_label(&shown.status, shown.busy),
                ),
                "modifiers": if darwin { vec!["cmd", "ctrl"] } else { vec!["ctrl", "alt"] },
                "held": self.held,
                "textSize": self.text_size,
                "terminal": shown.map(|shown| shown.label).unwrap_or_default(),
                "context": self.choosing.as_ref().map(Context::state),
            }),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn control_keys_paste_and_labels_read_as_the_qt_client() {
        assert_eq!(with_control("a"), "\u{1}");
        assert_eq!(with_control("C"), "\u{3}");
        assert_eq!(with_control("?"), "\u{7f}");
        assert_eq!(with_control("5"), "5");
        assert_eq!(with_control(""), "");
        assert_eq!(for_paste("a\nb\r\nc\td\u{7}e"), "a\rb\rc\td e");
        assert_eq!(status_label("running", true), "Task running");
        assert_eq!(status_label("running", false), "Ready");
        assert_eq!(status_label("", false), "Not started");
    }

    #[test]
    fn the_menu_lists_live_terminals_scripts_and_the_open_ones_actions() {
        let listed = |id: &str, status: &str| ListedTerminal {
            terminal_id: id.into(),
            label: format!("Terminal {id}"),
            status: status.into(),
            busy: false,
            cwd: "/home/user/shop".into(),
        };
        let listing = vec![listed("term-1", "running"), listed("term-2", "exited")];
        let scripts = vec![
            json!({"id": "test", "name": "Test", "command": "cargo test", "runOnWorktreeCreate": true}),
        ];
        let items = MobileTerminal::menu_items(&listing, "term-1", true, "shop", &scripts, 10.5);
        let ids: Vec<&str> = items.iter().map(|item| item.id.as_str()).collect();
        assert_eq!(
            ids,
            [
                "terminals",
                "new",
                "scripts",
                "context",
                "smaller",
                "larger",
                "close"
            ]
        );
        // The ended one is not the active one: it is not listed.
        let children: Vec<&str> = items[0].children.iter().map(|c| c.id.as_str()).collect();
        assert_eq!(children, ["terminal:term-1"]);
        assert!(items[0].children[0].checked);
        assert_eq!(items[2].children[0].label, "Test (setup)");
        // Shut: no context or text-size rows.
        let items = MobileTerminal::menu_items(&listing, "term-2", false, "shop", &[], 6.0);
        let ids: Vec<&str> = items.iter().map(|item| item.id.as_str()).collect();
        assert_eq!(ids, ["terminals", "new", "scripts"]);
        assert_eq!(items[0].children.len(), 2, "the ended active one is listed");
        assert_eq!(items[2].children[0].id, "no-scripts");
        assert!(!items[2].children[0].enabled);
        assert_eq!(folder_name("/home/user/shop/"), "shop");
        assert_eq!(folder_name(""), "");
    }

    #[test]
    fn attached_output_is_labelled_by_its_terminal_or_as_a_terminal() {
        assert_eq!(context_label("Build"), "Build (visible output)");
        assert_eq!(context_label(""), "Terminal (visible output)");
    }

    #[test]
    fn a_held_modifier_applies_once_to_a_key_or_an_arrow() {
        assert_eq!(
            apply_held("ctrl", "c", false),
            HeldInput::Write("\u{3}".into())
        );
        assert_eq!(apply_held("ctrl", "v", false), HeldInput::Paste);
        assert_eq!(apply_held("cmd", "v", true), HeldInput::Paste);
        assert_eq!(
            apply_held("alt", "x", false),
            HeldInput::Write("\u{1b}x".into())
        );
        assert_eq!(
            apply_held("ctrl", "\u{1b}[A", false),
            HeldInput::Write("\u{1b}[1;5A".into())
        );
        assert_eq!(
            apply_held("alt", "\u{1b}OB", false),
            HeldInput::Write("\u{1b}[1;3B".into())
        );
    }

    #[test]
    fn two_taps_bound_the_chosen_lines() {
        let mut context = Context::open(vec!["a".into(), "b".into(), "c".into(), " ".into()])
            .expect("lines to choose");
        assert_eq!(context.text(), "a\nb\nc");
        context.tap(2);
        assert_eq!(context.text(), "c");
        context.tap(0);
        assert_eq!(context.text(), "a\nb\nc");
        context.tap(99);
        assert_eq!(context.text(), "a\nb\nc");
        assert!(Context::open(vec![" ".into()]).is_none());
    }
}
