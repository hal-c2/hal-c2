//! `keybindings`, desktop-qt's KeybindingController: the shell's keymap, as
//! the `Keybindings` QML singleton. The default keymap with the user's rules
//! from the MC's keybindings.json merged over them (the config's
//! `keybindingRules`), run natively where the shell has the command
//! ([`Commands`]).
//!
//! The window registers one shortcut per sequence in `shortcuts` and hands
//! every activation to `press`. Who gets a key:
//!   - A command in the registry or a project script runs here, whatever has
//!     focus.
//!   - A key the shell has no command for is not a window shortcut; it stays
//!     with the focused control.
//!   - In a terminal, only a sequence that resolves to a native command with
//!     terminalFocus set is taken (mod+j, mod+d, mod+shift+d, mod+n, mod+w
//!     by default); every other chord reaches the terminal.
//!   - Unmodified keys are never registered.
//!   - The application menu's accelerators (mod+, for settings, the app
//!     zoom) come after every keymap binding, and are not rows in Settings.
//!
//! Settings → Keybindings edits the rules through the MC (`bindings`,
//! save/remove/reset) on every environment the user reaches; the shell's own
//! MC pushes the new rules back. A keybindings.json the MC cannot parse (its
//! config's `issues`) leaves the defaults in force and is told once, with a
//! way to open the file.
//!
//! Its state is [`Keymap`], a handle that is never busy, so a controller
//! asks for a label while it runs:
//!
//! ```ignore
//! let hint = Keymap::of(engine).shortcut_label(engine, "thread.undo");
//! ```
//!
//! What other controllers own reaches it through setters
//! ([`Keymap::set_palette_open`], [`Keymap::set_terminal_open`],
//! [`Keymap::set_preview_open`], [`Keymap::set_threads`],
//! [`Keymap::on_jump_hints`]), which those controllers call once they are
//! ported.

use std::cell::RefCell;
use std::cmp::Ordering;
use std::collections::{BTreeSet, HashSet};
use std::rc::Rc;
use std::sync::LazyLock;
use std::time::Duration;

use ljos::prelude::{Atom, Cx, Engine, QmlObject, Value, qml_impl, qml_singleton};
use ljos_runtime::{Time, TimerId};
use serde_json::json;

use crate::bridge::Bridge;
use crate::commands::Commands;
use crate::controller::{self, Controller, Init};
use crate::controllers::menus::Menus;
use crate::controllers::navigation::{Navigation, Route};
use crate::controllers::settings::Settings;
use crate::controllers::settings_scope::SettingsScope;
use crate::controllers::toasts::{Action, Toasts};
use crate::json::{self, Json};
use crate::keybindings::{self as keymap, Binding, Context, When, qt};

/// The appearance toggle's command, which the theme registers: held down, it
/// does not repeat.
pub const APPEARANCE_CYCLE: &str = "appearance.cycle";

/// What still runs while the command palette is open: the palette's own
/// modes and theme commands, and what belongs to the window.
pub const OVER_PALETTE: [&str; 11] = [
    "commandPalette.toggle",
    "filePicker.toggle",
    "projectSearch.toggle",
    "theme.select",
    "appearance.cycle",
    "themeEditor.toggle",
    "sidebar.toggle",
    "settings.open",
    "view.resetZoom",
    "view.zoomIn",
    "view.zoomOut",
];

/// The desktop application menu's accelerators. They are not keymap
/// bindings: Settings → Keybindings neither lists nor rebinds them, and a
/// keymap binding on the same key wins (the preview's zoom while it has
/// focus).
const MENU_KEYS: [(&str, &str); 5] = [
    ("mod+,", "settings.open"),
    ("mod+0", "view.resetZoom"),
    ("mod+=", "view.zoomIn"),
    ("mod++", "view.zoomIn"),
    ("mod+-", "view.zoomOut"),
];

/// Held this long, the jump modifier shows the sidebar's jump keys; a quick
/// shortcut shows none.
pub const JUMP_HINT_DELAY: Duration = Duration::from_millis(200);

/// "Keybindings updated" shows at most once in this long.
pub const RELOAD_TOAST_COOLDOWN: Duration = Duration::from_millis(2000);

const MALFORMED: &str = "keybindings.malformed-config";
const OPEN_FAILED: &str = "Unable to open keybindings file";

/// Where the keyboard is when a shortcut fires. All false: the chrome.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Focus {
    pub terminal: bool,
    pub composer: bool,
    pub editable: bool,
}

impl Focus {
    /// `{terminal, composer, editable}`, as the window passes it.
    pub fn from_json(value: &Json) -> Focus {
        let flag = |key: &str| value.get(key).and_then(Json::as_bool).unwrap_or(false);
        Focus {
            terminal: flag("terminal"),
            composer: flag("composer"),
            editable: flag("editable"),
        }
    }
}

/// The sidebar's thread keys, top to bottom, or `None` while it is not the
/// active one.
pub type Threads = Rc<dyn Fn(&Engine) -> Option<Vec<String>>>;
/// The jump keys of the sidebar's first nine rows (`labels`), shown or not.
pub type JumpHints = Rc<dyn Fn(&Engine, &[String], bool)>;

#[derive(Default)]
struct State {
    active: bool,
    mac: bool,
    terminal_open: bool,
    palette_open: bool,
    preview_open: bool,
    model_picker_open: bool,
    /// The user's rules, as the MC's config holds them.
    rules: Vec<Json>,
    /// The keymap in force, and each binding's sequence. Empty until the
    /// first `set_rules`, and after `set_mac`.
    bindings: Vec<Binding>,
    sequences: Vec<String>,
    /// Each menu accelerator's sequence, as MENU_KEYS.
    menu_sequences: Vec<String>,
    shortcuts: Vec<Json>,
    rows: Vec<Json>,
    saving: u32,
    file_path: String,
    /// The file's problem last told, so each is told once.
    file_issue: String,
    /// When "Keybindings updated" last showed.
    reload_toast_at: Option<Time>,
    jump_hint_timer: Option<TimerId>,
    /// The registry's size the shortcuts were last built for.
    commands: usize,
    /// Adding the native commands: the shortcuts are built once after.
    registering: bool,
}

#[derive(Default)]
struct Inner {
    state: RefCell<State>,
    threads: RefCell<Option<Threads>>,
    jump_hints: RefCell<Vec<JumpHints>>,
}

#[derive(Default)]
struct Slot(RefCell<Option<Keymap>>);

/// The keymap, from Rust: a handle, cheap to clone.
#[derive(Clone, Default)]
pub struct Keymap(Rc<Inner>);

impl std::fmt::Debug for Keymap {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let state = self.0.state.borrow();
        f.debug_struct("Keymap")
            .field("rules", &state.rules.len())
            .field("bindings", &state.bindings.len())
            .finish_non_exhaustive()
    }
}

/// The identifiers the settings page knows: the core ones and every one a
/// default condition uses.
static KNOWN_VARIABLES: LazyLock<HashSet<String>> = LazyLock::new(|| {
    let mut known: HashSet<String> = [
        "terminalFocus",
        "terminalOpen",
        "previewOpen",
        "composerDraft",
        "isWeb",
        "isDesktop",
        "true",
        "false",
    ]
    .iter()
    .map(|s| (*s).to_owned())
    .collect();
    for binding in keymap::default_bindings() {
        let mut names = Vec::new();
        if let Some(when) = &binding.when {
            when.identifiers(&mut names);
        }
        known.extend(names.into_iter().map(str::to_owned));
    }
    known
});

/// QString::localeAwareCompare, near enough for command ids and keys:
/// case-insensitive first.
fn collate(a: &str, b: &str) -> Ordering {
    a.to_lowercase()
        .cmp(&b.to_lowercase())
        .then_with(|| a.cmp(b))
}

fn text<'a>(value: &'a Json, key: &str) -> &'a str {
    value.get(key).and_then(Json::as_str).unwrap_or_default()
}

/// The rule a row stands for, as the MC stores it: as written, since the MC
/// matches it exactly, else as shown.
fn target(row: &Json) -> Json {
    if let Some(rule) = row.get("rule").and_then(Json::as_object)
        && !rule.is_empty()
    {
        return Json::Object(rule.clone());
    }
    let mut rule = json!({"command": text(row, "command"), "key": text(row, "key")});
    let when = text(row, "when").trim();
    if !when.is_empty() {
        rule["when"] = json!(when);
    }
    rule
}

/// Shows a toast once no controller is running.
fn toast(engine: &Engine, f: impl FnOnce(&mut Toasts, &Engine) + 'static) {
    Bridge::of(engine).defer(engine, move |engine| {
        controller::with::<Toasts, _>(engine, f);
    });
}

impl Keymap {
    /// The engine's keymap, with the defaults in force.
    pub fn of(engine: &Engine) -> Keymap {
        let slot = engine.extension::<Slot>();
        if let Some(keymap) = slot.0.borrow().clone() {
            return keymap;
        }
        let keymap = Keymap::default();
        keymap.0.state.borrow_mut().mac = cfg!(target_os = "macos");
        *slot.0.borrow_mut() = Some(keymap.clone());
        let commands = Commands::of(engine);
        if let Ok(obj) = engine.singleton::<KeybindingsObject>() {
            let shown = commands.object().map_or(Value::Undefined, Value::Object);
            let _ = Cx::new(engine, obj).set(KeybindingsObject::COMMANDS, shown);
            // What a brick knows only: the model picker it shows is open.
            let _ = engine.connect_by_name(obj, "modelPickerOpenChanged", move |engine, _| {
                let open = engine.read_by_name(obj, "modelPickerOpen");
                Keymap::of(engine).model_picker_changed(engine, matches!(open, Value::Bool(true)));
            });
        }
        // A command coming or going changes which keys are the shell's.
        commands.on_changed(|engine| {
            let keymap = Keymap::of(engine);
            let count = Commands::of(engine).len();
            let changed = {
                let mut s = keymap.0.state.borrow_mut();
                !s.registering && std::mem::replace(&mut s.commands, count) != count
            };
            if changed {
                keymap.refresh_shortcuts(engine);
            }
        });
        keymap.set_rules(engine, Vec::new());
        keymap
    }

    fn object(engine: &Engine) -> Option<Cx<'_>> {
        engine
            .singleton::<KeybindingsObject>()
            .ok()
            .map(|obj| Cx::new(engine, obj))
    }

    /// Registers the native commands and follows the MC's rules.
    pub(crate) fn activate(&self, engine: &Engine) {
        if std::mem::replace(&mut self.0.state.borrow_mut().active, true) {
            return;
        }
        let settings = Settings::of(engine);
        settings.on_config_changed(|engine| Keymap::of(engine).follow_rules(engine));
        // A reload of keybindings.json is confirmed, at most once every two
        // seconds.
        settings.on_keybindings_pushed(|engine| Keymap::of(engine).pushed(engine));
        // TODO(port): TerminalController::changed / isOpen — the terminal
        // calls `set_terminal_open`.
        // TODO(port): CommandPaletteController::openChanged — the palette
        // calls `set_palette_open`.
        // TODO(port): RightPanelController::isOpen / activeTab — the panel
        // calls `set_preview_open` (its Previews tab shown).
        // Conditions on the route, the running turn and the composer's draft
        // (draftThreadRoute, turnRunning, composerDraft).
        let bridge = Bridge::of(engine);
        for key in ["turn", "route", "panel", "composer"] {
            bridge.watch(engine, key, |engine, _| {
                Keymap::of(engine).refresh_shortcuts(engine);
            });
        }
        self.0.state.borrow_mut().registering = true;
        self.register_commands(engine);
        self.0.state.borrow_mut().registering = false;
        self.0.state.borrow_mut().commands = Commands::of(engine).len();
        self.refresh_shortcuts(engine);
        self.follow_rules(engine);
    }

    // -- What other controllers say ----------------------------------------

    /// Whether chords read as macOS ones (mod is Command).
    pub fn mac(&self) -> bool {
        self.0.state.borrow().mac
    }

    pub fn set_mac(&self, engine: &Engine, mac: bool) {
        let rules = {
            let mut s = self.0.state.borrow_mut();
            s.mac = mac;
            s.sequences.clear();
            s.bindings.clear();
            s.rules.clone()
        };
        self.set_rules(engine, rules);
    }

    /// The command palette opened or closed: while it is open the thread's
    /// keys wait.
    pub fn set_palette_open(&self, engine: &Engine, open: bool) {
        if std::mem::replace(&mut self.0.state.borrow_mut().palette_open, open) != open {
            self.refresh_shortcuts(engine);
        }
    }

    /// The thread's terminal drawer opened or closed (terminalOpen).
    pub fn set_terminal_open(&self, engine: &Engine, open: bool) {
        if std::mem::replace(&mut self.0.state.borrow_mut().terminal_open, open) != open {
            self.refresh_shortcuts(engine);
        }
    }

    /// The right panel shows its Previews tab (previewOpen).
    pub fn set_preview_open(&self, engine: &Engine, open: bool) {
        if std::mem::replace(&mut self.0.state.borrow_mut().preview_open, open) != open {
            self.refresh_shortcuts(engine);
        }
    }

    pub fn model_picker_open(&self) -> bool {
        self.0.state.borrow().model_picker_open
    }

    /// The model picker the composer shows is open (modelPickerOpen); what
    /// `Keybindings.modelPickerOpen = ...` does.
    pub fn set_model_picker_open(&self, engine: &Engine, open: bool) {
        if let Some(cx) = Keymap::object(engine) {
            let _ = cx.set(KeybindingsObject::MODEL_PICKER_OPEN, open);
        }
        self.model_picker_changed(engine, open);
    }

    fn model_picker_changed(&self, engine: &Engine, open: bool) {
        if std::mem::replace(&mut self.0.state.borrow_mut().model_picker_open, open) != open {
            self.refresh_shortcuts(engine);
        }
    }

    /// The sidebar's rows, for thread.next/previous and thread.jump.N.
    pub fn set_threads(&self, threads: Threads) {
        *self.0.threads.borrow_mut() = Some(threads);
    }

    /// Told when the sidebar's jump keys show or hide.
    pub fn on_jump_hints(&self, f: impl Fn(&Engine, &[String], bool) + 'static) {
        self.0.jump_hints.borrow_mut().push(Rc::new(f));
    }

    /// The thread jump modifier (the one thread.jump.1 is bound with) went
    /// down or up: held for a moment, the sidebar's first rows show their
    /// jump keys.
    pub fn set_jump_modifier_held(&self, engine: &Engine, held: bool) {
        if held {
            if self.0.state.borrow().jump_hint_timer.is_some() {
                return;
            }
            let timer = engine.call_at(engine.now() + JUMP_HINT_DELAY, |engine| {
                let keymap = Keymap::of(engine);
                keymap.0.state.borrow_mut().jump_hint_timer = None;
                let labels: Vec<String> = (1..=9)
                    .map(|n| keymap.shortcut_label(engine, &format!("thread.jump.{n}")))
                    .collect();
                keymap.jump_hints(engine, labels, true);
            });
            self.0.state.borrow_mut().jump_hint_timer = Some(timer);
            return;
        }
        let timer = self.0.state.borrow_mut().jump_hint_timer.take();
        if let Some(timer) = timer {
            engine.cancel_call(timer);
        }
        self.jump_hints(engine, Vec::new(), false);
    }

    /// A key went down or up anywhere in the application (Qt::Key): what
    /// desktop-qt's application event filter sees.
    ///
    /// Ljós has no application-wide key filter, so nothing calls this yet;
    /// the window must forward its key events.
    pub fn key_event(&self, engine: &Engine, key: i32, pressed: bool) {
        // Qt calls the Command key Control on macOS.
        let modifier = key == qt::KEY_CONTROL || (!self.mac() && key == qt::KEY_META);
        self.set_jump_modifier_held(engine, pressed && modifier);
    }

    fn jump_hints(&self, engine: &Engine, labels: Vec<String>, show: bool) {
        // TODO(port): SidebarController::setJumpHints — the sidebar listens
        // with `on_jump_hints`.
        let hooks = self.0.jump_hints.borrow().clone();
        let labels = Rc::new(labels);
        for hook in hooks {
            let labels = labels.clone();
            Bridge::of(engine).defer(engine, move |engine| hook(engine, &labels, show));
        }
    }

    // -- The keymap --------------------------------------------------------

    fn follow_rules(&self, engine: &Engine) {
        let config = Json::Object(Settings::of(engine).config());
        let rules = config
            .get("keybindingRules")
            .and_then(Json::as_array)
            .cloned()
            .unwrap_or_default();
        self.set_rules(engine, rules);
        self.follow_file(engine, &config);
    }

    /// The user's rules over the defaults, as the MC's config holds them.
    pub fn set_rules(&self, engine: &Engine, rules: Vec<Json>) {
        let count = {
            let mut s = self.0.state.borrow_mut();
            if s.rules == rules && !s.sequences.is_empty() {
                return;
            }
            let count = s.rules.len();
            s.bindings = keymap::merge(&rules);
            s.rules = rules;
            let mac = s.mac;
            s.sequences = s
                .bindings
                .iter()
                .map(|b| keymap::sequence(&b.shortcut, mac))
                .collect();
            s.menu_sequences = MENU_KEYS
                .iter()
                .filter_map(|(key, _)| keymap::parse_shortcut(key))
                .map(|shortcut| keymap::sequence(&shortcut, mac))
                .collect();
            count
        };
        Commands::of(engine).set_shortcuts(
            engine,
            Rc::new(|engine: &Engine, command: &str| {
                Keymap::of(engine).shortcut_label(engine, command)
            }),
        );
        self.refresh_shortcuts(engine);
        // A rule that changes nothing in force (one that does not parse)
        // still counts.
        let changed = self.refresh_rows();
        if changed || self.0.state.borrow().rules.len() != count {
            self.show_bindings(engine);
        }
    }

    /// The user's rules.
    pub fn rules(&self) -> Vec<Json> {
        self.0.state.borrow().rules.clone()
    }

    /// The keymap in force, oldest first.
    pub fn bindings(&self) -> Vec<Binding> {
        self.0.state.borrow().bindings.clone()
    }

    /// How many rules the user's keybindings.json holds over the defaults.
    pub fn custom_count(&self) -> usize {
        self.0.state.borrow().rules.len()
    }

    /// Settings → Keybindings' rows, sorted by command and key: {id,
    /// command, label, key, keyLabel, when, rule, source (Default, Custom or
    /// Project), defaultKey, defaultWhen, conflicts (command labels),
    /// canReset, canRemove, search}.
    pub fn rows(&self) -> Vec<Json> {
        self.0.state.borrow().rows.clone()
    }

    /// [{sequence, autoRepeat, chrome, composer, editable, terminal}]: every
    /// sequence the keymap binds, whether its shortcut is the shell's while
    /// the chrome, the composer's field, another text field or a terminal
    /// has focus, and whether holding it down repeats it.
    pub fn shortcuts(&self) -> Vec<Json> {
        self.0.state.borrow().shortcuts.clone()
    }

    fn context(&self, engine: &Engine, focus: Focus) -> Context {
        let bridge = Bridge::of(engine);
        let route_kind = bridge
            .published(engine, "route")
            .map(|r| text(&r, "kind").to_owned())
            .unwrap_or_default();
        // The composer holds text the user has not sent.
        let draft = bridge
            .published(engine, "composer")
            .is_some_and(|c| !text(&c, "text").trim().is_empty());
        let running = bridge
            .published(engine, "turn")
            .and_then(|t| t.get("running").and_then(Json::as_bool))
            .unwrap_or(false);
        let s = self.0.state.borrow();
        [
            ("previewOpen", s.preview_open),
            ("modelPickerOpen", s.model_picker_open),
            ("composerDraft", draft),
            ("terminalFocus", focus.terminal),
            ("composerFocus", focus.composer),
            ("editableFocus", focus.editable),
            ("terminalOpen", s.terminal_open),
            ("draftThreadRoute", route_kind == "draft"),
            ("turnRunning", running),
            ("isDesktop", true),
            ("isWeb", false),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_owned(), v))
        .collect()
    }

    /// The command `sequence` runs with that focus, or empty.
    pub fn resolve(&self, engine: &Engine, sequence: &str, focus: Focus) -> String {
        let context = self.context(engine, focus);
        self.resolve_in(sequence, &context)
    }

    fn resolve_in(&self, sequence: &str, context: &Context) -> String {
        let command = self.bound(sequence, context);
        // The palette is not modal: while it is open every other key stays
        // with it.
        if !command.is_empty()
            && !OVER_PALETTE.contains(&command.as_str())
            && self.0.state.borrow().palette_open
        {
            return String::new();
        }
        command
    }

    /// `resolve` before the open palette has its say: the newest binding
    /// whose condition holds, then the menu's accelerators.
    fn bound(&self, sequence: &str, context: &Context) -> String {
        let s = self.0.state.borrow();
        for (index, binding) in s.bindings.iter().enumerate().rev() {
            if s.sequences[index] == sequence && keymap::evaluate(binding.when.as_ref(), context) {
                return binding.command.clone();
            }
        }
        s.menu_sequences
            .iter()
            .position(|m| m == sequence)
            .map(|index| MENU_KEYS[index].1.to_owned())
            .unwrap_or_default()
    }

    /// A window shortcut fired with the keyboard at `focus`: true when the
    /// key ran a command here.
    pub fn press(&self, engine: &Engine, sequence: &str, focus: Focus) -> bool {
        let command = self.resolve(engine, sequence, focus);
        if Commands::of(engine).run(engine, &command) {
            return true;
        }
        if let Some(id) = keymap::script_id(&command) {
            Bridge::of(engine).dispatch(engine, "workspace.runScript", json!({"scriptId": id}));
            return true;
        }
        false
    }

    /// One entry per sequence; each flag says whether the key is the
    /// shell's with that focus.
    fn refresh_shortcuts(&self, engine: &Engine) {
        let commands = Commands::of(engine);
        commands.prune(engine);
        let focuses = [
            Focus::default(),
            Focus {
                composer: true,
                editable: true,
                ..Focus::default()
            },
            Focus {
                editable: true,
                ..Focus::default()
            },
            Focus {
                terminal: true,
                ..Focus::default()
            },
        ];
        let contexts = focuses.map(|focus| self.context(engine, focus));
        let sequences: Vec<String> = {
            let s = self.0.state.borrow();
            s.sequences
                .iter()
                .chain(&s.menu_sequences)
                .cloned()
                .collect()
        };
        let native = |command: &str| {
            commands.contains(engine, command) || keymap::script_id(command).is_some()
        };
        let mut seen = HashSet::new();
        let mut shortcuts = Vec::new();
        for sequence in sequences {
            if sequence.is_empty() || !seen.insert(sequence.clone()) {
                continue;
            }
            let [chrome, composer, editable, terminal] =
                contexts.each_ref().map(|c| self.resolve_in(&sequence, c));
            shortcuts.push(json!({
                "sequence": sequence,
                // Held down, a toggle that cycles must not spin through its
                // states.
                "autoRepeat": chrome != APPEARANCE_CYCLE,
                "chrome": native(&chrome),
                "composer": native(&composer),
                "editable": native(&editable),
                "terminal": native(&terminal),
            }));
        }
        {
            let mut s = self.0.state.borrow_mut();
            if s.shortcuts == shortcuts {
                return;
            }
            s.shortcuts = shortcuts.clone();
        }
        if let Some(cx) = Keymap::object(engine) {
            let shown = json::to_value(engine, &Json::Array(shortcuts));
            let _ = cx.set(KeybindingsObject::SHORTCUTS, shown);
        }
    }

    /// The label of the shortcut that runs `command` outside any focus, or
    /// empty (findEffectiveShortcutForCommand): the newest binding for the
    /// command whose key no newer binding has taken.
    pub fn shortcut_label(&self, engine: &Engine, command: &str) -> String {
        let context = self.context(engine, Focus::default());
        let s = self.0.state.borrow();
        let mut claimed = HashSet::new();
        for binding in s.bindings.iter().rev() {
            if !keymap::evaluate(binding.when.as_ref(), &context) {
                continue;
            }
            let label = keymap::label(&binding.shortcut, s.mac);
            if !claimed.insert(label.clone()) {
                continue;
            }
            if binding.command == command {
                return label;
            }
        }
        for (key, menu_command) in MENU_KEYS {
            let Some(shortcut) = keymap::parse_shortcut(key) else {
                continue;
            };
            let label = keymap::label(&shortcut, s.mac);
            if menu_command == command && !claimed.contains(&label) {
                return label;
            }
        }
        String::new()
    }

    /// Rebuilds the rows Settings → Keybindings lists; whether they changed.
    fn refresh_rows(&self) -> bool {
        let defaults = keymap::default_bindings();
        let (bindings, mac) = {
            let s = self.0.state.borrow();
            (s.bindings.clone(), s.mac)
        };
        let mut rows: Vec<Json> = Vec::with_capacity(bindings.len());
        for (index, binding) in bindings.iter().enumerate() {
            let key = keymap::key_text(&binding.shortcut);
            let when = keymap::when_text(binding.when.as_ref());
            let mut fallback = None;
            let mut same_when = None;
            let mut same = None;
            for entry in defaults.iter().filter(|e| e.command == binding.command) {
                fallback.get_or_insert(entry);
                if keymap::when_text(entry.when.as_ref()) != when {
                    continue;
                }
                same_when.get_or_insert(entry);
                if keymap::key_text(&entry.shortcut) == key {
                    same = Some(entry);
                    break;
                }
            }
            let standard = same.or(same_when).or(fallback);
            let source = if keymap::script_id(&binding.command).is_some() {
                "Project"
            } else if same.is_some() {
                "Default"
            } else {
                "Custom"
            };
            let label = keymap::command_label(&binding.command);
            let default_key = standard.map_or(String::new(), |s| keymap::key_text(&s.shortcut));
            let default_when =
                standard.map_or(String::new(), |s| keymap::when_text(s.when.as_ref()));
            let search = [binding.command.as_str(), &label, &key, &when, source]
                .join("\n")
                .to_lowercase();
            rows.push(json!({
                "id": format!("{}\n{}\n{}\n{}", binding.command, key, when, index),
                "command": binding.command,
                "label": label,
                "key": key,
                "keyLabel": keymap::label(&binding.shortcut, mac),
                "when": when,
                "rule": binding.rule.to_json(),
                "source": source,
                "defaultKey": default_key,
                "defaultWhen": default_when,
                "canReset": source == "Custom" && !default_key.is_empty(),
                "canRemove": source != "Default",
                "search": search,
            }));
        }
        rows.sort_by(|a, b| {
            collate(text(a, "command"), text(b, "command"))
                .then_with(|| collate(text(a, "key"), text(b, "key")))
        });
        let conflicts: Vec<Vec<String>> = rows
            .iter()
            .map(|row| conflicts_in(&rows, text(row, "id"), text(row, "key"), text(row, "when")))
            .collect();
        for (row, labels) in rows.iter_mut().zip(conflicts) {
            row["conflicts"] = json!(labels);
        }
        let mut s = self.0.state.borrow_mut();
        let changed = s.rows != rows;
        s.rows = rows;
        changed
    }

    fn show_bindings(&self, engine: &Engine) {
        let (rows, count) = {
            let s = self.0.state.borrow();
            (s.rows.clone(), s.rules.len())
        };
        if let Some(cx) = Keymap::object(engine) {
            engine.batch(|| {
                let shown = json::to_value(engine, &Json::Array(rows));
                let _ = cx.set(KeybindingsObject::BINDINGS, shown);
                let _ = cx.set(
                    KeybindingsObject::CUSTOM_COUNT,
                    i32::try_from(count).unwrap_or(i32::MAX),
                );
            });
        }
    }

    /// The command labels another binding on `key` (whose condition can
    /// also apply) runs, other than the row `row_id`.
    pub fn conflicts(&self, row_id: &str, key: &str, when: &str) -> Vec<String> {
        conflicts_in(&self.0.state.borrow().rows, row_id, key, when)
    }

    /// "mod+shift+y" as the rows show it: "Ctrl+Shift+Y", or "⇧⌘Y" on
    /// macOS.
    pub fn key_label(&self, key: &str) -> String {
        keymap::parse_shortcut(key)
            .map_or_else(|| key.to_owned(), |s| keymap::label(&s, self.mac()))
    }

    /// The key a recorder makes of a press (Qt::Key, modifiers).
    pub fn record_key(&self, key: i32, modifiers: i32) -> String {
        keymap::recorded_key(key, modifiers, self.mac())
    }

    /// Why a condition cannot be used, or empty (an empty condition is
    /// "always").
    pub fn when_error(expression: &str) -> String {
        let trimmed = expression.trim();
        if trimmed.is_empty() || keymap::parse_when(trimmed).is_some() {
            return String::new();
        }
        "Use variables with !, &&, ||, and parentheses.".into()
    }

    /// The identifiers in a condition no context sets, sorted.
    pub fn unknown_variables(expression: &str) -> Vec<String> {
        let parsed: Option<When> = keymap::parse_when(expression.trim());
        let mut names = Vec::new();
        if let Some(when) = &parsed {
            when.identifiers(&mut names);
        }
        names
            .into_iter()
            .filter(|n| !KNOWN_VARIABLES.contains(*n))
            .map(str::to_owned)
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect()
    }

    /// Every command a binding can be added for, sorted by label.
    pub fn command_options(&self) -> Vec<String> {
        let mut commands: Vec<String> = keymap::commands().to_vec();
        for binding in &self.0.state.borrow().bindings {
            if !commands.contains(&binding.command) {
                commands.push(binding.command.clone());
            }
        }
        commands.sort_by(|a, b| collate(&keymap::command_label(a), &keymap::command_label(b)));
        commands
    }

    // -- Changing the rules ------------------------------------------------

    /// A save or removal is on its way to the MC.
    pub fn saving(&self) -> bool {
        self.0.state.borrow().saving > 0
    }

    /// Binds `command` to `key` when `when` (empty: always), replacing the
    /// row `replacing` when it is one of `rows`.
    pub fn save(
        &self,
        engine: &Engine,
        command: &str,
        key: &str,
        when: &str,
        replacing: Option<&Json>,
    ) {
        let mut input = json!({"command": command, "key": key.trim()});
        if !when.trim().is_empty() {
            input["when"] = json!(when.trim());
        }
        if let Some(row) = replacing.filter(|r| r.as_object().is_some_and(|m| !m.is_empty())) {
            input["replace"] = target(row);
        }
        self.call(
            engine,
            "hal-c2.upsertKeybinding",
            input,
            "Unable to save keybinding",
            "The keybinding was not saved.",
        );
    }

    pub fn remove(&self, engine: &Engine, row: &Json) {
        self.call(
            engine,
            "hal-c2.removeKeybinding",
            target(row),
            "Unable to remove keybinding",
            "The keybinding was not removed.",
        );
    }

    /// Puts a custom row back to its command's default.
    pub fn reset(&self, engine: &Engine, row: &Json) {
        let default_key = text(row, "defaultKey");
        if default_key.is_empty() {
            return;
        }
        self.save(
            engine,
            text(row, "command"),
            default_key,
            text(row, "defaultWhen"),
            Some(row),
        );
    }

    /// Takes every rule of the user's away, once they say so: only the
    /// built-in bindings apply after.
    pub fn reset_all(&self, engine: &Engine) {
        let rules = self.rules();
        if rules.is_empty() {
            return;
        }
        let description = if rules.len() == 1 {
            "This removes your 1 custom keybinding.".to_owned()
        } else {
            format!("This removes your {} custom keybindings.", rules.len())
        };
        Bridge::of(engine).defer(engine, move |engine| {
            controller::with::<Menus, _>(engine, |menus, engine| {
                let accepted = Rc::new(move |engine: &Engine| {
                    let keymap = Keymap::of(engine);
                    for rule in &rules {
                        keymap.call(
                            engine,
                            "hal-c2.removeKeybinding",
                            rule.clone(),
                            "Unable to reset keybindings",
                            "A keybinding was not removed.",
                        );
                    }
                });
                menus.confirm(
                    engine,
                    "Reset every keybinding to its default?",
                    &description,
                    "Reset keybindings",
                    true,
                    Some(accepted),
                    None,
                );
            });
        });
    }

    /// The keymap is the user's on every environment they reach: the
    /// shell's own, and each other one that is online. The shell's own
    /// answers as `config.keybindings`.
    fn call(
        &self,
        engine: &Engine,
        method: &str,
        input: Json,
        failure_title: &'static str,
        failure: &'static str,
    ) {
        let Some(mc) = controller::mc(engine) else {
            return;
        };
        let mut environments = vec![mc.environment()];
        // The store's environments, as the settings scope has them (TODO(port)
        // there: ShellStore::environments / environmentOnline).
        let scope = SettingsScope::of(engine);
        for id in scope.listed(engine) {
            if !environments.contains(&id) && scope.online(engine, &id) {
                environments.push(id);
            }
        }
        let idle = self.0.state.borrow().saving == 0;
        for environment in environments {
            self.0.state.borrow_mut().saving += 1;
            mc.call(
                &environment,
                method,
                input.clone(),
                Box::new(move |engine, result| {
                    let keymap = Keymap::of(engine);
                    let done = {
                        let mut s = keymap.0.state.borrow_mut();
                        s.saving = s.saving.saturating_sub(1);
                        s.saving == 0
                    };
                    if done {
                        keymap.show_saving(engine);
                    }
                    if let Err(error) = result {
                        let message = if error.message.is_empty() {
                            failure.to_owned()
                        } else {
                            error.message
                        };
                        toast(engine, move |toasts, engine| {
                            toasts.error(engine, failure_title, &message);
                        });
                    }
                }),
            );
        }
        if idle {
            self.show_saving(engine);
        }
    }

    fn show_saving(&self, engine: &Engine) {
        let saving = self.saving();
        if let Some(cx) = Keymap::object(engine) {
            let _ = cx.set(KeybindingsObject::SAVING, saving);
        }
    }

    // -- keybindings.json --------------------------------------------------

    /// Where the MC keeps keybindings.json, or empty before it says.
    pub fn file_path(&self) -> String {
        self.0.state.borrow().file_path.clone()
    }

    /// An unreadable keybindings.json is a warning naming the file, with
    /// the file one click away.
    fn follow_file(&self, engine: &Engine, config: &Json) {
        let path = text(config, "keybindingsConfigPath").to_owned();
        let moved = {
            let mut s = self.0.state.borrow_mut();
            (s.file_path != path).then(|| s.file_path = path.clone())
        };
        if moved.is_some()
            && let Some(cx) = Keymap::object(engine)
        {
            let _ = cx.set(KeybindingsObject::FILE_PATH, Atom::from(path.as_str()));
        }
        let issue = config
            .get("issues")
            .and_then(Json::as_array)
            .into_iter()
            .flatten()
            .filter(|entry| text(entry, "kind") == MALFORMED)
            .map(|entry| text(entry, "message").to_owned())
            .next_back()
            .unwrap_or_default();
        {
            let mut s = self.0.state.borrow_mut();
            if s.file_issue == issue {
                return;
            }
            s.file_issue = issue.clone();
        }
        if issue.is_empty() {
            return;
        }
        toast(engine, move |toasts, engine| {
            toasts.show(
                engine,
                "warning",
                "Invalid keybindings configuration",
                &issue,
                Some(Action::new("Open keybindings.json", |engine| {
                    Keymap::of(engine).open_file(engine);
                })),
                0,
            );
        });
    }

    /// Opens keybindings.json on the MC in the editor last used there, else
    /// the first it has; says so when it cannot.
    pub fn open_file(&self, engine: &Engine) {
        let path = self.file_path();
        if path.is_empty() {
            return;
        }
        let settings = Settings::of(engine);
        let available: Vec<Json> = settings
            .config()
            .get("availableEditors")
            .and_then(Json::as_array)
            .cloned()
            .unwrap_or_default();
        let last = settings
            .device_value("lastEditor")
            .and_then(|v| v.as_str().map(str::to_owned))
            .unwrap_or_default();
        let editor = if available.contains(&json!(last)) {
            last
        } else {
            available
                .first()
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        if editor.is_empty() {
            toast(engine, |toasts, engine| {
                toasts.error(engine, OPEN_FAILED, "No available editors found.");
            });
            return;
        }
        settings.write_device(engine, "lastEditor", json!(editor));
        let Some(mc) = controller::mc(engine) else {
            return;
        };
        mc.call(
            &mc.environment(),
            "shell.openInEditor",
            json!({"cwd": path, "editor": editor}),
            Box::new(|engine, result| {
                if let Err(error) = result {
                    let message = if error.message.is_empty() {
                        "The keybindings file was not opened.".to_owned()
                    } else {
                        error.message
                    };
                    toast(engine, move |toasts, engine| {
                        toasts.error(engine, OPEN_FAILED, &message);
                    });
                }
            }),
        );
    }

    /// The MC pushed new rules: confirmed, at most once a cooldown.
    fn pushed(&self, engine: &Engine) {
        let now = engine.now();
        {
            let mut s = self.0.state.borrow_mut();
            if s.reload_toast_at
                .is_some_and(|at| at + RELOAD_TOAST_COOLDOWN > now)
            {
                return;
            }
            s.reload_toast_at = Some(now);
        }
        toast(engine, |toasts, engine| {
            toasts.show(
                engine,
                "success",
                "Keybindings updated",
                "Keybindings configuration reloaded successfully.",
                None,
                crate::controllers::toasts::DEFAULT_TIMEOUT_MS,
            );
        });
    }

    // -- The native commands -----------------------------------------------

    /// The commands the shell has natively. A command no one registers (the
    /// in-app browser's preview keys) does nothing.
    fn register_commands(&self, engine: &Engine) {
        let commands = Commands::of(engine);
        let add = |command: &str, run: Box<dyn Fn(&Engine)>| {
            commands.add(engine, command, &keymap::command_label(command), run);
        };
        add(
            "navigation.back",
            Box::new(|engine| {
                controller::with::<Navigation, _>(engine, |n, engine| n.back(engine));
            }),
        );
        add(
            "navigation.forward",
            Box::new(|engine| {
                controller::with::<Navigation, _>(engine, |n, engine| n.forward(engine));
            }),
        );
        add(
            "thread.previous",
            Box::new(|engine| Keymap::of(engine).traverse(engine, false)),
        );
        add(
            "thread.next",
            Box::new(|engine| Keymap::of(engine).traverse(engine, true)),
        );
        for n in 1..=9usize {
            add(
                &format!("thread.jump.{n}"),
                Box::new(move |engine| {
                    let keys = Keymap::of(engine).threads(engine);
                    if let Some(key) = keys.and_then(|keys| keys.get(n - 1).cloned()) {
                        jump_to(engine, &key);
                    }
                }),
            );
        }
        // TODO(port): TerminalController::supported — the terminal's port
        // calls `add_terminal_commands` in a build that has one.
        //
        // The route thread's running turn stops, as the composer's stop
        // button does.
        add(
            "thread.stop",
            Box::new(|engine| {
                Bridge::of(engine).dispatch(engine, "composer.interrupt", Json::Null);
            }),
        );
        // The route thread's first queued message steers the running turn.
        add(
            "thread.steerQueuedMessage",
            Box::new(|engine| {
                Bridge::of(engine).dispatch(engine, "composer.queue.steer", Json::Null);
            }),
        );
        // The composer brick edits the last queued message when its caret
        // is at the start, and moves the caret there otherwise.
        add(
            "thread.editQueuedMessage",
            Box::new(|engine| bricks(engine, "composer.queue.editLast", Json::Null)),
        );
        // The composer brick sends its draft the other way, or in the
        // background (its own Enter chords do the same while it has the
        // keyboard).
        for (command, intent) in [
            ("composer.sendAlternate", "alternate"),
            ("composer.sendBackground", "background"),
        ] {
            add(
                command,
                Box::new(move |engine| {
                    bricks(engine, "composer.submit.key", json!({"intent": intent}));
                }),
            );
        }
        // The composer brick hands the stash its latest text first.
        add(
            "composer.stash",
            Box::new(|engine| bricks(engine, "composer.stash.key", Json::Null)),
        );
        // The composer brick opens its own pickers.
        add(
            "modelPicker.toggle",
            Box::new(|engine| bricks(engine, "composer.modelPicker.toggle", Json::Null)),
        );
        for command in [
            "composer.effort",
            "composer.mode",
            "composer.host",
            "composer.workspace",
            "composer.branch",
        ] {
            add(
                command,
                Box::new(move |engine| {
                    bricks(engine, "composer.control.open", json!({"command": command}));
                }),
            );
        }
        // TODO(port): ThreadMenuController::togglePin / toggleSettle — the
        // thread menu's port adds "thread.pin" and "thread.settle" (the
        // route thread's, as its menu has them).
        //
        // Undo is the newest toast's (ThreadMenuController::undo).
        add(
            "thread.undo",
            Box::new(|engine| {
                controller::with::<Toasts, _>(engine, |toasts, engine| {
                    toasts.run_action(engine, "Undo");
                });
            }),
        );
    }

    /// The native terminals' commands, through the bridge like the drawer's
    /// buttons; split and close act on the focused terminal. A build without
    /// a terminal has none of them, in the palette or under a key.
    pub fn add_terminal_commands(&self, engine: &Engine) {
        let commands = Commands::of(engine);
        for action in [
            "terminal.toggle",
            "terminal.new",
            "terminal.close",
            "terminal.split",
            "terminal.splitVertical",
        ] {
            commands.add(
                engine,
                action,
                &keymap::command_label(action),
                move |engine| {
                    Bridge::of(engine).dispatch(engine, action, Json::Null);
                },
            );
        }
    }

    fn threads(&self, engine: &Engine) -> Option<Vec<String>> {
        // TODO(port): SidebarController::isActive / orderedKeys — the
        // sidebar calls `set_threads`.
        let source = self.0.threads.borrow().clone();
        source.and_then(|threads| threads(engine))
    }

    /// The sidebar's next or previous row (resolveAdjacentThreadId): from
    /// nothing open, the first or last; nothing past either end.
    fn traverse(&self, engine: &Engine, next: bool) {
        let Some(keys) = self.threads(engine) else {
            return;
        };
        if keys.is_empty() {
            return;
        }
        let current = current_thread(engine);
        if current.is_empty() {
            let edge = if next { keys.first() } else { keys.last() };
            if let Some(key) = edge {
                jump_to(engine, key);
            }
            return;
        }
        let Some(index) = keys.iter().position(|k| *k == current) else {
            return;
        };
        let target = if next {
            index.checked_add(1)
        } else {
            index.checked_sub(1)
        };
        if let Some(key) = target.and_then(|t| keys.get(t)) {
            jump_to(engine, key);
        }
    }
}

fn conflicts_in(rows: &[Json], row_id: &str, key: &str, when: &str) -> Vec<String> {
    if key.trim().is_empty() {
        return Vec::new();
    }
    let mut labels: Vec<String> = Vec::new();
    for row in rows {
        if text(row, "id") == row_id || text(row, "key") != key {
            continue;
        }
        let row_when = text(row, "when");
        if !row_when.is_empty() && !when.is_empty() && row_when != when {
            continue;
        }
        let label = text(row, "label");
        if !labels.iter().any(|l| l == label) {
            labels.push(label.to_owned());
        }
    }
    labels.sort();
    labels
}

fn bricks(engine: &Engine, action: &str, payload: Json) {
    Bridge::of(engine).send_to_bricks(engine, action, &payload);
}

/// The thread the window shows, or empty.
fn current_thread(engine: &Engine) -> String {
    Bridge::of(engine)
        .published(engine, "route")
        .and_then(|r| r.get("threadKey").and_then(Json::as_str).map(str::to_owned))
        .unwrap_or_default()
}

fn jump_to(engine: &Engine, key: &str) {
    if current_thread(engine) == key {
        return;
    }
    let key = key.to_owned();
    controller::with::<Navigation, _>(engine, move |n, engine| {
        n.open(engine, Route::Thread(key));
    });
}

/// `Keybindings` in QML.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "Keybindings", uncreatable)]
#[qml_singleton]
pub struct KeybindingsObject {
    /// The command registry (CommandRegistry).
    #[qml(notify, readonly)]
    commands: Value,
    #[qml(notify, readonly)]
    shortcuts: Value,
    #[qml(notify, readonly)]
    bindings: Value,
    #[qml(notify, readonly)]
    custom_count: i32,
    #[qml(notify, readonly)]
    saving: bool,
    /// Set by the model picker brick.
    #[qml(notify)]
    model_picker_open: bool,
    #[qml(notify, readonly)]
    file_path: Atom,
}

impl Default for KeybindingsObject {
    fn default() -> Self {
        KeybindingsObject {
            commands: Value::Undefined,
            shortcuts: Value::Undefined,
            bindings: Value::Undefined,
            custom_count: 0,
            saving: false,
            model_picker_open: false,
            file_path: Atom::from(""),
        }
    }
}

fn strings(engine: &Engine, list: Vec<String>) -> Value {
    json::to_value(engine, &json!(list))
}

fn object_of(engine: &Engine, value: &Value) -> Option<Json> {
    let json = json::from_value(engine, value);
    json.is_object().then_some(json)
}

#[qml_impl]
impl KeybindingsObject {
    /// A window shortcut fired; `focus` is {terminal, composer, editable}.
    #[qml(invokable)]
    fn press(cx: &Cx, sequence: Atom, focus: Value) -> bool {
        let focus = Focus::from_json(&json::from_value(cx.engine, &focus));
        Keymap::of(cx.engine).press(cx.engine, &sequence, focus)
    }

    #[qml(invokable)]
    fn shortcut_label(cx: &Cx, command: Atom) -> Atom {
        Atom::from(
            Keymap::of(cx.engine)
                .shortcut_label(cx.engine, &command)
                .as_str(),
        )
    }

    #[qml(invokable)]
    fn record_key(cx: &Cx, key: i32, modifiers: i32) -> Atom {
        Atom::from(Keymap::of(cx.engine).record_key(key, modifiers).as_str())
    }

    #[qml(invokable)]
    fn key_label(cx: &Cx, key: Atom) -> Atom {
        Atom::from(Keymap::of(cx.engine).key_label(&key).as_str())
    }

    #[qml(invokable)]
    fn command_label(_cx: &Cx, command: Atom) -> Atom {
        Atom::from(keymap::command_label(&command).as_str())
    }

    #[qml(invokable)]
    fn when_error(_cx: &Cx, expression: Atom) -> Atom {
        Atom::from(Keymap::when_error(&expression).as_str())
    }

    #[qml(invokable)]
    fn unknown_variables(cx: &Cx, expression: Atom) -> Value {
        strings(cx.engine, Keymap::unknown_variables(&expression))
    }

    #[qml(invokable)]
    fn conflicts(cx: &Cx, row_id: Atom, key: Atom, when: Atom) -> Value {
        strings(
            cx.engine,
            Keymap::of(cx.engine).conflicts(&row_id, &key, &when),
        )
    }

    #[qml(invokable)]
    fn command_options(cx: &Cx) -> Value {
        strings(cx.engine, Keymap::of(cx.engine).command_options())
    }

    #[qml(invokable)]
    fn save(cx: &Cx, command: Atom, key: Atom, when: Value, replacing: Value) {
        let when = match json::from_value(cx.engine, &when) {
            Json::String(when) => when,
            _ => String::new(),
        };
        let replacing = object_of(cx.engine, &replacing);
        Keymap::of(cx.engine).save(cx.engine, &command, &key, &when, replacing.as_ref());
    }

    #[qml(invokable)]
    fn remove(cx: &Cx, row: Value) {
        let row = json::from_value(cx.engine, &row);
        Keymap::of(cx.engine).remove(cx.engine, &row);
    }

    #[qml(invokable)]
    fn reset(cx: &Cx, row: Value) {
        let row = json::from_value(cx.engine, &row);
        Keymap::of(cx.engine).reset(cx.engine, &row);
    }

    #[qml(invokable)]
    fn reset_all(cx: &Cx) {
        Keymap::of(cx.engine).reset_all(cx.engine);
    }

    #[qml(invokable)]
    fn open_file(cx: &Cx) {
        Keymap::of(cx.engine).open_file(cx.engine);
    }
}

/// The controller: activates the keymap and handles its actions.
/// Everything else is [`Keymap`].
pub struct KeybindingController {
    keymap: Keymap,
}

impl Controller for KeybindingController {
    fn new(init: Init<'_, Self>) -> Self {
        KeybindingController {
            keymap: Keymap::of(init.engine),
        }
    }

    fn activate(&mut self, engine: &Engine) {
        self.keymap.activate(engine);
    }

    /// Keys reach it through `press`, never as actions.
    fn handle(&mut self, engine: &Engine, action: &str, _payload: &Json) -> bool {
        match action {
            "keybindings.resetAll" => self.keymap.reset_all(engine),
            "keybindings.openFile" => self.keymap.open_file(engine),
            _ => return false,
        }
        true
    }
}

impl KeybindingController {
    pub fn keymap(&self) -> Keymap {
        self.keymap.clone()
    }

    /// The label of the shortcut that runs `command`, or empty.
    pub fn shortcut_label(&self, engine: &Engine, command: &str) -> String {
        self.keymap.shortcut_label(engine, command)
    }
}
