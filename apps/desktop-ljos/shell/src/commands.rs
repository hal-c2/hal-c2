//! The commands the shell runs itself, desktop-qt's CommandRegistry: by
//! keybinding command id (packages/contracts keybindings.ts) or, for one
//! without a key, an id of its owner's (`settings.open`). What a key press,
//! the command palette or a menu runs. The palette lists every one as an
//! action. Each row is {command, title, shortcut, description, enabled,
//! listed}; the `Keybindings` singleton fills in the shortcut label from the
//! user's keymap.
//!
//! Rust owners add a function ([`Commands::add`]); QML adds a callback owned
//! by an object, and the command goes when that object does:
//!
//! ```qml
//! Keybindings.commands.add("appearance.cycle", qsTr("Cycle appearance"), () => cycle(), owner)
//! ```
//!
//! An owner keeps what the palette shows current: its title and description,
//! whether it can run now (a disabled command does nothing) and whether the
//! palette lists it at all (its key still runs it). A menu
//! ([`Commands::add_menu`]) is a command whose run shows its choices in the
//! palette, as "Change theme" does.
//!
//! One registry per engine ([`Commands::of`]), so any controller may add to
//! it whenever it likes, without reaching the keybindings controller.

use std::cell::{Cell, RefCell};
use std::fmt;
use std::rc::Rc;

use ljos::prelude::{Atom, Cx, Engine, ModelSignals, ObjectId, QmlListModel, QmlObject, RowKey};
use ljos::prelude::{Value, qml_impl};

use crate::bridge::Bridge;

/// What a command or a choice runs. It runs once no controller is running
/// (`Bridge::defer`), so it may reach any of them.
pub type Run = Rc<dyn Fn(&Engine)>;
/// A menu's choices, read each time it is shown.
pub type Choices = Rc<dyn Fn(&Engine) -> Vec<Choice>>;
/// The label of a command's shortcut, or empty.
pub type LabelFor = Rc<dyn Fn(&Engine, &str) -> String>;
type Hook = Rc<dyn Fn(&Engine, &str)>;
type FailedHook = Rc<dyn Fn(&Engine, &str, &str)>;
type Changed = Rc<dyn Fn(&Engine)>;

/// One of a menu's choices. `current` marks the one in effect ("Current");
/// `submenu`, when set, opens further choices instead of running;
/// `keep_open` leaves the palette open after `run` (a choice that moves the
/// palette on).
#[derive(Clone)]
pub struct Choice {
    pub id: String,
    pub title: String,
    pub description: String,
    pub current: bool,
    pub enabled: bool,
    pub terms: Vec<String>,
    pub run: Option<Run>,
    pub submenu: Option<Choices>,
    pub keep_open: bool,
}

impl Choice {
    /// An enabled choice that runs `run`.
    pub fn new(id: &str, title: &str, run: impl Fn(&Engine) + 'static) -> Choice {
        Choice {
            id: id.to_owned(),
            title: title.to_owned(),
            description: String::new(),
            current: false,
            enabled: true,
            terms: Vec::new(),
            run: Some(Rc::new(run)),
            submenu: None,
            keep_open: false,
        }
    }
}

impl fmt::Debug for Choice {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Choice")
            .field("id", &self.id)
            .field("title", &self.title)
            .field("current", &self.current)
            .field("enabled", &self.enabled)
            .finish_non_exhaustive()
    }
}

/// A row as the palette reads it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Row {
    pub command: String,
    pub title: String,
    pub shortcut: String,
    pub description: String,
    pub enabled: bool,
    pub listed: bool,
    pub terms: Vec<String>,
    pub menu: bool,
}

#[derive(Clone)]
enum Runner {
    Native(Run),
    /// A QML callback; one that throws fails the command.
    Js(Value),
    Menu,
}

struct Entry {
    /// Its row's key while it is in the model.
    key: RowKey,
    row: Row,
    runner: Runner,
    /// The object a QML command goes with.
    owner: Option<ObjectId>,
    choices: Option<Choices>,
}

#[derive(Default)]
struct Inner {
    entries: RefCell<Vec<Entry>>,
    next_key: Cell<RowKey>,
    object: Cell<Option<ObjectId>>,
    signals: RefCell<Option<ModelSignals>>,
    label_for: RefCell<Option<LabelFor>>,
    ran: RefCell<Vec<Hook>>,
    failed: RefCell<Vec<FailedHook>>,
    menu_requested: RefCell<Vec<Hook>>,
    changed: RefCell<Vec<Changed>>,
}

/// The registry, from Rust: a handle, cheap to clone.
#[derive(Clone, Default)]
pub struct Commands(Rc<Inner>);

impl fmt::Debug for Commands {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Commands")
            .field("count", &self.0.entries.borrow().len())
            .finish()
    }
}

#[derive(Default)]
struct Registry(RefCell<Option<Commands>>);

/// `Keybindings.commands` in QML: the registry as a list model, with
/// `count`, `add`, `remove`, `contains` and `run`.
#[derive(Debug, Default, QmlObject)]
#[qml(module = "HalC2.Shell", name = "CommandRegistry", uncreatable)]
pub struct CommandRegistry {
    #[qml(notify, readonly)]
    count: i32,
}

#[qml_impl]
impl CommandRegistry {
    /// Adds `command`, run by `callback`, until `owner` goes.
    #[qml(invokable)]
    fn add(cx: &Cx, command: Atom, title: Atom, callback: Value, owner: Value) {
        let commands = Commands::of(cx.engine);
        let owner = match owner {
            Value::Object(id) => Some(id),
            _ => None,
        };
        commands.add_js(cx.engine, &command, &title, callback, owner);
    }

    #[qml(invokable)]
    fn remove(cx: &Cx, command: Atom) {
        Commands::of(cx.engine).remove(cx.engine, &command);
    }

    #[qml(invokable)]
    fn contains(cx: &Cx, command: Atom) -> bool {
        Commands::of(cx.engine).contains(cx.engine, &command)
    }

    #[qml(invokable)]
    fn run(cx: &Cx, command: Atom) -> bool {
        Commands::of(cx.engine).run(cx.engine, &command)
    }
}

struct Rows(Rc<Inner>);

const ROLES: [&str; 6] = [
    "command",
    "title",
    "shortcut",
    "description",
    "enabled",
    "listed",
];

impl QmlListModel for Rows {
    fn row_count(&self) -> usize {
        self.0.entries.borrow().len()
    }

    fn role_names(&self) -> Vec<Atom> {
        ROLES.iter().map(|r| Atom::from(*r)).collect()
    }

    fn data(&self, row: usize, role: &str) -> Value {
        let entries = self.0.entries.borrow();
        let Some(entry) = entries.get(row) else {
            return Value::Undefined;
        };
        let row = &entry.row;
        match role {
            "command" => Value::from(row.command.as_str()),
            "title" => Value::from(row.title.as_str()),
            "shortcut" => Value::from(row.shortcut.as_str()),
            "description" => Value::from(row.description.as_str()),
            "enabled" => Value::Bool(row.enabled),
            "listed" => Value::Bool(row.listed),
            _ => Value::Undefined,
        }
    }

    fn row_key(&self, row: usize) -> RowKey {
        self.0
            .entries
            .borrow()
            .get(row)
            .map_or(row as RowKey, |e| e.key)
    }
}

impl Commands {
    /// The engine's registry, made with its QML object on first use.
    pub fn of(engine: &Engine) -> Commands {
        let registry = engine.extension::<Registry>();
        if let Some(commands) = registry.0.borrow().clone() {
            return commands;
        }
        let commands = Commands::default();
        *registry.0.borrow_mut() = Some(commands.clone());
        if let Ok(obj) = engine.create_native(CommandRegistry::default(), None) {
            commands.0.object.set(Some(obj));
            if let Ok(signals) = engine.set_list_model(obj, Rc::new(Rows(commands.0.clone()))) {
                *commands.0.signals.borrow_mut() = Some(signals);
            }
        }
        commands
    }

    /// The QML object, `Keybindings.commands`.
    pub fn object(&self) -> Option<ObjectId> {
        self.0.object.get()
    }

    /// Adds `command`, or replaces what it runs.
    pub fn add(
        &self,
        engine: &Engine,
        command: &str,
        title: &str,
        run: impl Fn(&Engine) + 'static,
    ) {
        self.insert(
            engine,
            command,
            title,
            Runner::Native(Rc::new(run)),
            None,
            None,
        );
    }

    /// A QML callback, owned by `owner`: the command goes when it does. Not
    /// a function (as far as Rust can tell): nothing is added.
    pub fn add_js(
        &self,
        engine: &Engine,
        command: &str,
        title: &str,
        callback: Value,
        owner: Option<ObjectId>,
    ) {
        // Ljós cannot say whether a JS value is callable; anything that is
        // not a JS value certainly is not.
        if !matches!(callback, Value::Js(_)) {
            return;
        }
        self.insert(engine, command, title, Runner::Js(callback), owner, None);
    }

    /// Adds `command` as a menu of `choices`, read each time it is shown.
    pub fn add_menu(
        &self,
        engine: &Engine,
        command: &str,
        title: &str,
        choices: impl Fn(&Engine) -> Vec<Choice> + 'static,
    ) {
        self.insert(
            engine,
            command,
            title,
            Runner::Menu,
            None,
            Some(Rc::new(choices)),
        );
    }

    /// A replaced command keeps how its owner presents it.
    fn insert(
        &self,
        engine: &Engine,
        command: &str,
        title: &str,
        runner: Runner,
        owner: Option<ObjectId>,
        choices: Option<Choices>,
    ) {
        self.prune(engine);
        let label_for = self.0.label_for.borrow().clone();
        let shortcut = label_for.map_or(String::new(), |l| l(engine, command));
        let replaced = {
            let mut entries = self.0.entries.borrow_mut();
            match entries.iter().position(|e| e.row.command == command) {
                Some(index) => {
                    let kept = &mut entries[index];
                    kept.row.title = title.to_owned();
                    kept.row.menu = choices.is_some();
                    kept.runner = runner.clone();
                    kept.choices = choices.clone();
                    kept.owner = owner;
                    Some(index)
                }
                None => None,
            }
        };
        if let Some(index) = replaced {
            self.row_changed(engine, index, &[]);
            return;
        }
        let row = self.0.entries.borrow().len();
        let key = self.0.next_key.get();
        self.0.next_key.set(key + 1);
        let signals = self.0.signals.borrow().clone();
        if let Some(s) = &signals {
            s.rows_about_to_be_inserted(engine, row, 1);
        }
        self.0.entries.borrow_mut().push(Entry {
            key,
            row: Row {
                command: command.to_owned(),
                title: title.to_owned(),
                shortcut,
                description: String::new(),
                enabled: true,
                listed: true,
                terms: Vec::new(),
                menu: choices.is_some(),
            },
            runner,
            owner,
            choices,
        });
        if let Some(s) = &signals {
            s.rows_inserted(engine, row, 1);
        }
        self.count_changed(engine);
    }

    pub fn remove(&self, engine: &Engine, command: &str) {
        let Some(index) = self.index_of(command) else {
            return;
        };
        self.remove_at(engine, index);
        self.count_changed(engine);
    }

    fn remove_at(&self, engine: &Engine, index: usize) {
        let signals = self.0.signals.borrow().clone();
        if let Some(s) = &signals {
            s.rows_about_to_be_removed(engine, index, 1);
        }
        self.0.entries.borrow_mut().remove(index);
        if let Some(s) = &signals {
            s.rows_removed(engine, index, 1);
        }
    }

    /// Takes away the QML commands whose owner is gone.
    ///
    /// Ljós tells Rust nothing when an object is destroyed (Qt's
    /// `QObject::destroyed`), so a dead owner's command goes the next time
    /// the registry is used, not at once.
    pub fn prune(&self, engine: &Engine) {
        let mut pruned = false;
        loop {
            let dead = self
                .0
                .entries
                .borrow()
                .iter()
                .position(|e| e.owner.is_some_and(|o| !engine.is_alive(o)));
            let Some(index) = dead else { break };
            self.remove_at(engine, index);
            pruned = true;
        }
        if pruned {
            self.count_changed(engine);
        }
    }

    /// How many commands are registered (owners gone or not).
    pub fn len(&self) -> usize {
        self.0.entries.borrow().len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn contains(&self, engine: &Engine, command: &str) -> bool {
        self.prune(engine);
        self.index_of(command).is_some()
    }

    fn index_of(&self, command: &str) -> Option<usize> {
        self.0
            .entries
            .borrow()
            .iter()
            .position(|e| e.row.command == command)
    }

    /// Runs `command` (a menu asks to be shown: `on_menu_requested`); false
    /// when no one registered it. A disabled one is registered but does
    /// nothing. It runs once no controller is running, so a controller may
    /// run a command that reaches back into it.
    pub fn run(&self, engine: &Engine, command: &str) -> bool {
        self.prune(engine);
        let runner = {
            let entries = self.0.entries.borrow();
            let Some(entry) = entries.iter().find(|e| e.row.command == command) else {
                return false;
            };
            if !entry.row.enabled {
                return true;
            }
            entry.runner.clone()
        };
        let me = self.clone();
        let command = command.to_owned();
        Bridge::of(engine).defer(engine, move |engine| {
            let failure = match runner {
                Runner::Native(run) => {
                    run(engine);
                    None
                }
                // Ljós's call_js says only that the call threw, not why:
                // the message is empty.
                Runner::Js(callback) => engine.call_js(&callback, &[]).is_none().then(String::new),
                Runner::Menu => {
                    me.emit(engine, &me.0.menu_requested, &command);
                    None
                }
            };
            me.emit(engine, &me.0.ran, &command);
            if let Some(message) = failure {
                let hooks = me.0.failed.borrow().clone();
                for hook in hooks {
                    hook(engine, &command, &message);
                }
            }
        });
        true
    }

    fn emit(&self, engine: &Engine, hooks: &RefCell<Vec<Hook>>, command: &str) {
        let hooks = hooks.borrow().clone();
        for hook in hooks {
            hook(engine, command);
        }
    }

    /// Changes one row's field, notifying only when it changed.
    fn change(&self, engine: &Engine, command: &str, role: &str, f: impl FnOnce(&mut Row) -> bool) {
        let changed = {
            let mut entries = self.0.entries.borrow_mut();
            entries
                .iter()
                .position(|e| e.row.command == command)
                .filter(|&index| f(&mut entries[index].row))
        };
        if let Some(index) = changed {
            self.row_changed(engine, index, &[role]);
        }
    }

    pub fn set_title(&self, engine: &Engine, command: &str, title: &str) {
        self.change(engine, command, "title", |r| {
            set(&mut r.title, title.to_owned())
        });
    }

    pub fn set_description(&self, engine: &Engine, command: &str, description: &str) {
        self.change(engine, command, "description", |r| {
            set(&mut r.description, description.to_owned())
        });
    }

    pub fn set_enabled(&self, engine: &Engine, command: &str, enabled: bool) {
        self.change(engine, command, "enabled", |r| set(&mut r.enabled, enabled));
    }

    pub fn set_listed(&self, engine: &Engine, command: &str, listed: bool) {
        self.change(engine, command, "listed", |r| set(&mut r.listed, listed));
    }

    /// Search words beside the title: searched, not shown, so no row
    /// changes.
    pub fn set_terms(&self, command: &str, terms: &[&str]) {
        let mut entries = self.0.entries.borrow_mut();
        if let Some(entry) = entries.iter_mut().find(|e| e.row.command == command) {
            entry.row.terms = terms.iter().map(|t| (*t).to_owned()).collect();
        }
    }

    pub fn terms(&self, command: &str) -> Vec<String> {
        self.0
            .entries
            .borrow()
            .iter()
            .find(|e| e.row.command == command)
            .map(|e| e.row.terms.clone())
            .unwrap_or_default()
    }

    pub fn is_menu(&self, command: &str) -> bool {
        self.0
            .entries
            .borrow()
            .iter()
            .any(|e| e.row.command == command && e.choices.is_some())
    }

    /// A menu's choices now; empty for any other command.
    pub fn choices(&self, engine: &Engine, command: &str) -> Vec<Choice> {
        let choices = self
            .0
            .entries
            .borrow()
            .iter()
            .find(|e| e.row.command == command)
            .and_then(|e| e.choices.clone());
        choices.map_or_else(Vec::new, |c| c(engine))
    }

    /// Every row, in the model's order.
    pub fn rows(&self) -> Vec<Row> {
        self.0
            .entries
            .borrow()
            .iter()
            .map(|e| e.row.clone())
            .collect()
    }

    /// The label of each command's shortcut, now and for commands added
    /// later; only rows whose label changed notify.
    pub fn set_shortcuts(&self, engine: &Engine, label_for: LabelFor) {
        *self.0.label_for.borrow_mut() = Some(label_for.clone());
        let commands: Vec<String> = self
            .0
            .entries
            .borrow()
            .iter()
            .map(|e| e.row.command.clone())
            .collect();
        for command in commands {
            let label = label_for(engine, &command);
            self.change(engine, &command, "shortcut", |r| {
                set(&mut r.shortcut, label)
            });
        }
    }

    /// After `command` ran.
    pub fn on_ran(&self, f: impl Fn(&Engine, &str) + 'static) {
        self.0.ran.borrow_mut().push(Rc::new(f));
    }

    /// A menu command ran: whoever shows menus (the palette) shows its
    /// choices.
    pub fn on_menu_requested(&self, f: impl Fn(&Engine, &str) + 'static) {
        self.0.menu_requested.borrow_mut().push(Rc::new(f));
    }

    /// `command` ran and failed, saying why (empty: it did not say).
    pub fn on_failed(&self, f: impl Fn(&Engine, &str, &str) + 'static) {
        self.0.failed.borrow_mut().push(Rc::new(f));
    }

    /// Rows came, went or changed: the palette rebuilds.
    pub fn on_changed(&self, f: impl Fn(&Engine) + 'static) {
        self.0.changed.borrow_mut().push(Rc::new(f));
    }

    fn row_changed(&self, engine: &Engine, index: usize, roles: &[&str]) {
        let signals = self.0.signals.borrow().clone();
        if let Some(s) = signals {
            s.data_changed(engine, index, 1, roles);
        }
        self.changed(engine);
    }

    fn count_changed(&self, engine: &Engine) {
        let count = i32::try_from(self.0.entries.borrow().len()).unwrap_or(i32::MAX);
        if let Some(obj) = self.0.object.get() {
            let _ = Cx::new(engine, obj).set(CommandRegistry::COUNT, count);
        }
        self.changed(engine);
    }

    fn changed(&self, engine: &Engine) {
        let hooks = self.0.changed.borrow().clone();
        for hook in hooks {
            hook(engine);
        }
    }
}

fn set<T: PartialEq>(field: &mut T, value: T) -> bool {
    if *field == value {
        return false;
    }
    *field = value;
    true
}
