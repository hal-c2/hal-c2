//! `palette`, desktop-qt's CommandPaletteController: the command palette, as
//! the `PaletteModel` QML singleton and the list the CommandPalette brick
//! shows. It has five modes:
//!
//!   - command (commandPalette.toggle, mod+k). With no query, the
//!     hand-picked actions ([`ROOT_COMMANDS`], each while its owner lists
//!     it) and Recent Threads. A query adds every listed command in
//!     [`Commands`], the sidebar's projects, the settings sections the brick
//!     hands over (js/settingsPages.js, those whose `requires` state is
//!     there), each keybinding command and the shell's threads (by key
//!     `environmentId:threadId`, subagent ones left out, and archived ones
//!     too unless the query finds their linked pull request, when each is
//!     marked "Linked thread" or "Archived thread"); from two characters on,
//!     threads whose messages match too (`orchestration.searchThreads` on
//!     every online environment). A query filters and ranks the rows; a
//!     leading ">" keeps to actions. A menu command ([`Commands::add_menu`])
//!     opens its choices as a submenu; Backspace on an empty query leaves it.
//!   - files (filePicker.toggle): the route thread's files by name
//!     (`projects.searchEntries`); choosing one opens it in the right panel.
//!   - content (projectSearch.toggle): text across them
//!     (`projects.searchContents`, with the case, whole word and regular
//!     expression options), matches grouped by file; choosing one opens its
//!     file at the line.
//!   - browse (Add project's Local folder, [`browse`]): the query is a path
//!     on an environment (`filesystem.browse`); choosing a folder goes into
//!     it, and Enter with none highlighted hands the path to the browser. A
//!     clone's destination browses with the repository's folder name pinned
//!     to the path ([`BrowseOptions`]).
//!   - ask (a clone's repository, [`ask`]): the query is free text, nothing
//!     is listed, and Enter hands it to the asker, which moves the palette
//!     on or closes it ([`finish`]).
//!
//! Searches against the MC wait for typing to pause ([`SEARCH_DELAY_MS`])
//! and only the newest answer counts; files and content only while the
//! route thread's environment is online, starting afresh when it moves to
//! another project. Each row is {title, description, group, shortcut, kind,
//! runnable, current}; a query change moves only the rows that differ,
//! never resetting the list.
//!
//! Dismissing it gives the composer its keyboard back (`composer.focus` to
//! the bricks); running an entry leaves focus to what the entry opened. A
//! command that fails says so ("Unable to run command").
//!
//! Other controllers reach it through the free functions, which run once no
//! controller is running, so any controller may call them while it runs:
//!
//! ```ignore
//! palette::ask(engine, "Git URL", "Enter Git clone URL", "", |engine, url| { .. });
//! ```

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::rc::Rc;
use std::time::Duration;

use ljos::prelude::{Atom, Cx, Engine, ModelSignals, ObjectId, QmlListModel, QmlObject, RowKey};
use ljos::prelude::{TimerId, Value, qml_impl, qml_singleton};
use serde_json::json;
use unicode_general_category::{GeneralCategory, get_general_category};
use unicode_normalization::UnicodeNormalization;

use crate::bridge::Bridge;
use crate::commands::{Choice, Choices, Commands};
use crate::controller::{self, Controller, Init};
use crate::controllers::keybindings::Keymap;
use crate::controllers::navigation::{self, KEYBINDINGS_SECTION, Navigation, Route};
use crate::controllers::panel::RightPanel;
use crate::controllers::toasts::Toasts;
use crate::controllers::{drafts, sidebar};
use crate::json::Json;
use crate::keybindings as keymap;
use crate::mc::{Mc, McError};
use crate::sidebar_model;
use crate::store;

pub const TOGGLE: &str = "commandPalette.toggle";
pub const FILES: &str = "filePicker.toggle";
pub const CONTENT: &str = "projectSearch.toggle";

/// The root list with no query, in order.
pub const ROOT_COMMANDS: [&str; 15] = [
    "chat.new",
    "thread.newIn",
    "thread.copyReference",
    "thread.linkPullRequest",
    "thread.showPullRequests",
    FILES,
    CONTENT,
    "project.add",
    "theme.select",
    "appearance.select",
    "themeEditor.toggle",
    "pullRequests.open",
    "usage.open",
    "settings.open",
    "projectSettings.open",
];

pub const RECENT_THREADS: usize = 12;
/// How long typing pauses before a search against the MC.
pub const SEARCH_DELAY_MS: u64 = 120;
const FILE_LIMIT: i32 = 200;
const CONTENT_LIMIT: i32 = 500;
const MESSAGE_LIMIT: i32 = 20;

const ACTIONS: &str = "Actions";
const DIRECTORIES: &str = "Directories";

/// What an ask or a browse hands on: the text or path chosen.
type Callback = Rc<dyn Fn(&Engine, &str)>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Mode {
    Command,
    Files,
    Content,
    Browse,
    Ask,
}

impl Mode {
    fn name(self) -> &'static str {
        match self {
            Mode::Command => "command",
            Mode::Files => "files",
            Mode::Content => "content",
            Mode::Browse => "browse",
            Mode::Ask => "ask",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Action,
    Thread,
    Project,
    Setting,
    Choice,
    File,
    Match,
    Folder,
    Up,
}

impl Kind {
    fn name(self) -> &'static str {
        match self {
            Kind::Action => "action",
            Kind::Thread => "thread",
            Kind::Project => "project",
            Kind::Setting => "setting",
            Kind::Choice => "choice",
            Kind::File => "file",
            Kind::Match => "match",
            Kind::Folder => "folder",
            Kind::Up => "up",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
struct Entry {
    kind: Kind,
    /// A command, thread key, project key, settings path, choice id, file
    /// path, "path:line" or folder path.
    id: String,
    title: String,
    description: String,
    shortcut: String,
    /// Normalized search fields, most telling first, and all of them joined.
    terms: Vec<String>,
    haystack: String,
    /// Threads: when the user last wrote in it, for ties and the recent list.
    recency: i64,
    enabled: bool,
    current: bool,
    /// Content matches: the file's group; folders: Directories.
    group: String,
    /// A keybinding command among the settings: listed after every setting.
    secondary: bool,
    /// Threads: what its linked pull requests are found by, and whether it
    /// is archived (found by those alone, and said to be).
    pull_requests: String,
    archived: bool,
}

impl Entry {
    fn new(kind: Kind, id: impl Into<String>, title: impl Into<String>) -> Entry {
        Entry {
            kind,
            id: id.into(),
            title: title.into(),
            description: String::new(),
            shortcut: String::new(),
            terms: Vec::new(),
            haystack: String::new(),
            recency: 0,
            enabled: true,
            current: false,
            group: String::new(),
            secondary: false,
            pull_requests: String::new(),
            archived: false,
        }
    }

    fn described(mut self, description: impl Into<String>) -> Entry {
        self.description = description.into();
        self
    }

    fn found_by(mut self, terms: Vec<String>) -> Entry {
        self.terms = terms;
        self
    }
}

/// A row the view shows. It keeps what it shows: a row reads the same until
/// the model says it changed, whatever the entries hold meanwhile.
#[derive(Clone, Debug)]
struct Row {
    group: String,
    /// Its index in the entries (and a submenu's choices) when it was listed.
    entry: usize,
    /// Its group and entry id, which say whether a row moved.
    key: String,
    /// A thread found by its messages shows the matching snippet.
    description: String,
    item: Entry,
    /// What the view knows it by while it stays.
    row_key: RowKey,
}

impl Row {
    fn description(&self) -> &str {
        if self.description.is_empty() {
            &self.item.description
        } else {
            &self.description
        }
    }

    /// What the view shows of it.
    fn shows(&self) -> (&str, &str, &str, &str, Kind, bool, bool) {
        let e = &self.item;
        (
            &e.title,
            self.description(),
            &self.group,
            &e.shortcut,
            e.kind,
            e.enabled,
            e.current,
        )
    }
}

/// A submenu: the menu's title, its choices when it opened, and where they
/// come from.
struct View {
    title: String,
    choices: Vec<Choice>,
    source: Option<Choices>,
}

/// Where files and content are searched: the route thread's environment and
/// folder.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct Target {
    environment_id: String,
    root: String,
}

/// How browse mode starts and what choosing does: `query` is where it
/// starts; `pinned`, when set, is a folder name kept at the end of the path
/// (a clone's "<chosen folder>/<repo>"); `empty_text` replaces the
/// palette's own; `submit` is the verb of the button that names Enter;
/// `keep_open` leaves the palette open when the path is chosen, for the
/// chooser to close ([`finish`]) once it is done.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BrowseOptions {
    pub query: String,
    pub pinned: String,
    pub empty_text: String,
    pub submit: String,
    pub keep_open: bool,
}

impl Default for BrowseOptions {
    fn default() -> Self {
        BrowseOptions {
            query: "~/".into(),
            pinned: String::new(),
            empty_text: String::new(),
            submit: "Add".into(),
            keep_open: false,
        }
    }
}

/// What `PaletteModel` shows, as last written to it.
#[derive(Clone, Debug, PartialEq)]
struct Props {
    open: bool,
    mode: &'static str,
    submenu: String,
    placeholder: String,
    query: String,
    highlighted: i32,
    count: i32,
    empty_text: String,
    status: String,
    submit_label: String,
    submit_shortcut: String,
    case_sensitive: bool,
    whole_word: bool,
    use_regex: bool,
}

impl Default for Props {
    fn default() -> Self {
        Props {
            open: false,
            mode: Mode::Command.name(),
            submenu: String::new(),
            placeholder: String::new(),
            query: String::new(),
            highlighted: 0,
            count: 0,
            empty_text: String::new(),
            status: String::new(),
            submit_label: String::new(),
            submit_shortcut: String::new(),
            case_sensitive: false,
            whole_word: false,
            use_regex: false,
        }
    }
}

// -- The model ---------------------------------------------------------------

/// The rows views read, with the count they were told of.
#[derive(Default)]
struct List {
    rows: RefCell<Vec<Row>>,
    next_key: Cell<RowKey>,
    signals: RefCell<Option<ModelSignals>>,
}

const ROLES: [&str; 7] = [
    "title",
    "description",
    "group",
    "shortcut",
    "kind",
    "runnable",
    "current",
];

impl QmlListModel for List {
    fn row_count(&self) -> usize {
        self.rows.borrow().len()
    }

    fn role_names(&self) -> Vec<Atom> {
        ROLES.iter().map(|r| Atom::from(*r)).collect()
    }

    fn data(&self, row: usize, role: &str) -> Value {
        let rows = self.rows.borrow();
        let Some(row) = rows.get(row) else {
            return Value::Undefined;
        };
        let e = &row.item;
        match role {
            "title" => Value::from(e.title.as_str()),
            "description" => Value::from(row.description()),
            "group" => Value::from(row.group.as_str()),
            "shortcut" => Value::from(e.shortcut.as_str()),
            "kind" => Value::from(e.kind.name()),
            "runnable" => Value::Bool(e.enabled),
            "current" => Value::Bool(e.current),
            _ => Value::Undefined,
        }
    }

    fn row_key(&self, row: usize) -> RowKey {
        self.rows
            .borrow()
            .get(row)
            .map_or(row as RowKey, |r| r.row_key)
    }
}

impl List {
    fn fresh_key(&self) -> RowKey {
        let key = self.next_key.get();
        self.next_key.set(key + 1);
        key
    }
}

// -- Search text ---------------------------------------------------------------

/// Search text: compatibility-decomposed, marks dropped, lower case,
/// whitespace collapsed.
fn normalize(text: &str) -> String {
    let out: String = text
        .nfkd()
        .filter(|&c| {
            !matches!(
                get_general_category(c),
                GeneralCategory::NonspacingMark
                    | GeneralCategory::SpacingMark
                    | GeneralCategory::EnclosingMark
            )
        })
        .flat_map(char::to_lowercase)
        .collect();
    simplified(&out)
}

fn simplified(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn has_all(field: &str, tokens: &[&str]) -> bool {
    tokens.iter().all(|t| field.contains(t))
}

/// rankCommandPaletteItemMatch: the first field every token is in decides,
/// by its place and how well the whole query matches it (exact, prefix,
/// then substring); recency breaks ties.
fn rank(terms: &[String], query: &str, tokens: &[&str]) -> i32 {
    let mut index = 0;
    for field in terms {
        if field.is_empty() {
            continue;
        }
        if has_all(field, tokens) {
            let field_rank = if field == query {
                3
            } else if field.starts_with(query) {
                2
            } else if field.contains(query) {
                1
            } else {
                0
            };
            return 1000 - index * 100 + field_rank;
        }
        index += 1;
    }
    0
}

/// searchSettings' own rank, which orders settings the generic rank ties:
/// the title matched exactly, by prefix, containing the query, every token
/// in it, the phrase anywhere, then the rest.
fn settings_rank(terms: &[String], query: &str, tokens: &[&str]) -> i32 {
    let title = terms.first().map_or("", String::as_str);
    if title == query {
        5
    } else if title.starts_with(query) {
        4
    } else if title.contains(query) {
        3
    } else if has_all(title, tokens) {
        2
    } else if terms.iter().any(|f| f.contains(query)) {
        1
    } else {
        0
    }
}

fn text<'a>(object: &'a Json, key: &str) -> &'a str {
    object.get(key).and_then(Json::as_str).unwrap_or_default()
}

/// What a thread's linked pull requests are found by: "#N", the
/// repository's "owner/repo#N", the URL and the title, for each one the
/// user did not dismiss.
fn pull_request_terms(row: Option<&store::Row>) -> Vec<String> {
    let links = row
        .and_then(|r| r.get("pullRequests"))
        .and_then(Json::as_array)
        .cloned()
        .unwrap_or_default();
    let mut terms = Vec::new();
    for link in &links {
        if text(link, "source") == "stack-dismissed" {
            continue;
        }
        let n = &link["number"];
        let number = format!(
            "#{}",
            n.as_i64()
                .or_else(|| n.as_f64().map(|f| f as i64))
                .unwrap_or(0)
        );
        terms.push(number.clone());
        terms.push(format!("{}{number}", text(link, "repository")));
        terms.push(text(link, "url").to_owned());
        terms.push(text(&link["snapshot"], "title").to_owned());
    }
    terms
}

fn directory_of(path: &str) -> &str {
    path.rfind('/').map_or("", |slash| &path[..slash])
}

fn name_of(path: &str) -> &str {
    path.rfind('/').map_or(path, |slash| &path[slash + 1..])
}

/// The folder a path is in, as QFileInfo::path says it.
fn parent_of(path: &str) -> String {
    match path.rfind('/') {
        None => ".".into(),
        Some(0) => "/".into(),
        Some(slash) => path[..slash].into(),
    }
}

fn value_text(value: &Value) -> String {
    match value {
        Value::String(s) => s.as_str().to_owned(),
        _ => String::new(),
    }
}

fn value_int(value: &Value) -> i32 {
    let n = value.to_number();
    if n.is_finite() {
        n.clamp(i32::MIN as f64, i32::MAX as f64) as i32
    } else {
        0
    }
}

// -- The controller ------------------------------------------------------------

pub struct Palette {
    bridge: Bridge,
    mc: Rc<dyn Mc>,
    object: Option<ObjectId>,
    list: Rc<List>,
    /// What `PaletteModel` shows now, which QML writes reach too.
    props: Rc<RefCell<Props>>,
    active: bool,
    open: bool,
    mode: Mode,
    views: Vec<View>,
    query: String,
    highlighted: i32,
    settings_sections: Vec<Json>,
    /// The `requires` keys already followed.
    requires: HashSet<String>,
    entries: Vec<Entry>,
    /// The command being run from the palette, whose failure is toasted.
    running: Option<String>,
    /// Searches against the MC: the debounce, the newest one's generation,
    /// and how many answers are still to come.
    timer: Option<TimerId>,
    generation: u64,
    pending: usize,
    target: Target,
    truncated: bool,
    error: String,
    invalid_regex: bool,
    case_sensitive: bool,
    whole_word: bool,
    use_regex: bool,
    /// Threads whose messages match the query: key to snippet.
    message_matches: HashMap<String, String>,
    message_query: String,
    /// Browse mode: the environment, its answer, and what adding does.
    browse_environment: String,
    browse_query: String,
    browse_parent: String,
    browse_entries: Vec<Json>,
    add: Option<Callback>,
    browse_options: BrowseOptions,
    /// Ask mode: its title, placeholder, empty text and what Enter does.
    ask_title: String,
    ask_placeholder: String,
    ask_empty: String,
    submit: Option<Callback>,
}

/// Runs `f` on the palette once no controller is running, then shows what
/// it changed.
fn later(engine: &Engine, f: impl FnOnce(&mut Palette, &Engine) + 'static) {
    Bridge::of(engine).defer(engine, move |engine| {
        controller::with::<Palette, _>(engine, |c, engine| {
            f(c, engine);
            c.sync(engine);
        });
    });
}

/// Runs `f` on the palette now, then shows what it changed; false when it
/// is busy.
fn now(engine: &Engine, f: impl FnOnce(&mut Palette, &Engine) -> bool) -> bool {
    controller::with::<Palette, _>(engine, |c, engine| {
        let done = f(c, engine);
        c.sync(engine);
        done
    })
    .unwrap_or(false)
}

/// Opens the palette in command mode.
pub fn show(engine: &Engine) {
    later(engine, |c, engine| c.show(engine));
}

/// Opens it, or dismisses it when open.
pub fn toggle(engine: &Engine) {
    later(engine, |c, engine| c.toggle(engine));
}

/// Opens it in `mode` (files, content, else command), or closes it when it
/// is open in that mode.
pub fn toggle_mode(engine: &Engine, mode: &str) {
    let mode = mode.to_owned();
    later(engine, move |c, engine| c.toggle_mode(engine, &mode));
}

/// Opens the palette on the menu `command`'s choices.
pub fn show_menu(engine: &Engine, command: &str) {
    let command = command.to_owned();
    later(engine, move |c, engine| c.show_menu(engine, &command));
}

/// Browses folders on `environment_id` from `options.query`; `add` is given
/// the path chosen, once no controller is running.
pub fn browse(
    engine: &Engine,
    environment_id: &str,
    add: impl Fn(&Engine, &str) + 'static,
    options: BrowseOptions,
) {
    let environment_id = environment_id.to_owned();
    later(engine, move |c, engine| {
        c.browse(engine, &environment_id, Rc::new(add), options);
    });
}

/// Asks for a line of text under `title` (ask mode): Enter gives the query,
/// trimmed and not empty, to `submit`, which leaves the palette open.
pub fn ask(
    engine: &Engine,
    title: &str,
    placeholder: &str,
    empty_text: &str,
    submit: impl Fn(&Engine, &str) + 'static,
) {
    let (title, placeholder, empty) = (
        title.to_owned(),
        placeholder.to_owned(),
        empty_text.to_owned(),
    );
    later(engine, move |c, engine| {
        c.ask(engine, title, placeholder, empty, Rc::new(submit));
    });
}

/// Closes it after an ask or a browse that kept it open.
pub fn finish(engine: &Engine) {
    later(engine, |c, engine| c.close(engine, false));
}

/// Reads the submenu shown again from its source, as when what it lists
/// arrived after it opened.
pub fn refresh_menu(engine: &Engine) {
    later(engine, |c, engine| c.refresh_menu(engine));
}

impl Controller for Palette {
    fn new(init: Init<'_, Self>) -> Self {
        let engine = init.engine;
        let list = Rc::new(List::default());
        let props = Rc::new(RefCell::new(Props::default()));
        let object = init.bridge.singleton::<PaletteObject>(engine).ok();
        if let Some(obj) = object {
            if let Ok(signals) = engine.set_list_model(obj, list.clone() as Rc<dyn QmlListModel>) {
                *list.signals.borrow_mut() = Some(signals);
            }
            follow_writes(engine, obj, &props);
        }
        Palette {
            bridge: init.bridge,
            mc: init.mc,
            object,
            list,
            props,
            active: false,
            open: false,
            mode: Mode::Command,
            views: Vec::new(),
            query: String::new(),
            highlighted: 0,
            settings_sections: Vec::new(),
            requires: HashSet::new(),
            entries: Vec::new(),
            running: None,
            timer: None,
            generation: 0,
            pending: 0,
            target: Target::default(),
            truncated: false,
            error: String::new(),
            invalid_regex: false,
            case_sensitive: false,
            whole_word: false,
            use_regex: false,
            message_matches: HashMap::new(),
            message_query: String::new(),
            browse_environment: String::new(),
            browse_query: String::new(),
            browse_parent: String::new(),
            browse_entries: Vec::new(),
            add: None,
            browse_options: BrowseOptions::default(),
            ask_title: String::new(),
            ask_placeholder: String::new(),
            ask_empty: String::new(),
            submit: None,
        }
    }

    /// Registers the toggles and follows what the palette lists.
    fn activate(&mut self, engine: &Engine) {
        if std::mem::replace(&mut self.active, true) {
            return;
        }
        let commands = Commands::of(engine);
        commands.add(engine, TOGGLE, &keymap::command_label(TOGGLE), toggle);
        commands.add(engine, FILES, "Go to file", |engine| {
            toggle_mode(engine, "files");
        });
        commands.add(engine, CONTENT, "Search project contents", |engine| {
            toggle_mode(engine, "content");
        });
        commands.set_terms(
            FILES,
            &[
                "go to file",
                "open file",
                "file picker",
                "find file",
                "quick open",
            ],
        );
        commands.set_terms(
            CONTENT,
            &[
                "search project",
                "find in files",
                "grep",
                "content search",
                "text search",
            ],
        );
        let rebuild = |engine: &Engine| later(engine, |c, engine| c.rebuild(engine));
        commands.on_changed(rebuild);
        Keymap::of(engine).on_bindings_changed(rebuild);
        commands.on_menu_requested(show_menu);
        commands.on_failed(|engine, command, message| {
            let ours = controller::with::<Palette, _>(engine, |c, _| {
                c.running.as_deref() == Some(command)
            })
            .unwrap_or(false);
            if !ours {
                return;
            }
            let message = if message.is_empty() {
                "An unexpected error occurred."
            } else {
                message
            };
            controller::with::<Toasts, _>(engine, |t, engine| {
                t.error(engine, "Unable to run command", message);
            });
        });
        // The current thread's mark, and where files are searched.
        let follow = |engine: &Engine| {
            later(engine, |c, engine| {
                c.follow_target(engine);
                c.rebuild(engine);
            });
        };
        store::on_changed(engine, follow);
        self.bridge
            .watch(engine, "route", move |engine, _| follow(engine));
        self.target = target(engine);
    }

    /// What its keys run, dispatched as actions too (a scripted render
    /// opens the palette with `--action commandPalette.toggle`).
    fn handle(&mut self, engine: &Engine, action: &str, _payload: &Json) -> bool {
        match action {
            TOGGLE => self.toggle(engine),
            FILES => self.toggle_mode(engine, "files"),
            CONTENT => self.toggle_mode(engine, "content"),
            _ => return false,
        }
        self.sync(engine);
        true
    }
}

/// QML's writes to `query`, `highlighted` and the content options go to the
/// palette, which may change them again.
fn follow_writes(engine: &Engine, obj: ObjectId, props: &Rc<RefCell<Props>>) {
    on_write(
        engine,
        obj,
        props,
        "query",
        value_text,
        |p| &mut p.query,
        |c, engine, query| c.set_query(engine, &query),
    );
    on_write(
        engine,
        obj,
        props,
        "highlighted",
        value_int,
        |p| &mut p.highlighted,
        |c, _, row| c.set_highlighted(row),
    );
    on_write(
        engine,
        obj,
        props,
        "caseSensitive",
        Value::to_boolean,
        |p| &mut p.case_sensitive,
        |c, engine, on| c.set_case_sensitive(engine, on),
    );
    on_write(
        engine,
        obj,
        props,
        "wholeWord",
        Value::to_boolean,
        |p| &mut p.whole_word,
        |c, engine, on| c.set_whole_word(engine, on),
    );
    on_write(
        engine,
        obj,
        props,
        "useRegex",
        Value::to_boolean,
        |p| &mut p.use_regex,
        |c, engine, on| c.set_use_regex(engine, on),
    );
}

/// A write to `name` that is not the palette's own (what it shows already)
/// is handed to `apply`. The highlight arrives clamped, by its setter
/// ([`PaletteObject::keep_highlighted`]).
fn on_write<T: Clone + PartialEq + 'static>(
    engine: &Engine,
    obj: ObjectId,
    props: &Rc<RefCell<Props>>,
    name: &'static str,
    read: fn(&Value) -> T,
    field: fn(&mut Props) -> &mut T,
    apply: fn(&mut Palette, &Engine, T),
) {
    let props = props.clone();
    let _ = engine.connect_by_name(obj, &format!("{name}Changed"), move |engine, _| {
        let value = read(&engine.read_by_name(obj, name));
        {
            let mut shown = props.borrow_mut();
            let shown = field(&mut shown);
            if *shown == value {
                return;
            }
            *shown = value.clone();
        }
        later(engine, move |c, engine| apply(c, engine, value));
    });
}

impl Palette {
    // -- What tests and the bricks read -------------------------------------

    pub fn is_open(&self) -> bool {
        self.open
    }

    /// command, files, content, browse or ask.
    pub fn mode(&self) -> &'static str {
        self.mode.name()
    }

    pub fn query(&self) -> &str {
        &self.query
    }

    pub fn highlighted(&self) -> i32 {
        self.highlighted
    }

    pub fn count(&self) -> i32 {
        i32::try_from(self.list.rows.borrow().len()).unwrap_or(i32::MAX)
    }

    /// Whether a search against the MC is on its way.
    pub fn searching(&self) -> bool {
        self.pending > 0 || self.timer.is_some()
    }

    fn row(&self, row: i32) -> Option<Row> {
        let row = usize::try_from(row).ok()?;
        self.list.rows.borrow().get(row).cloned()
    }

    /// The row's entry kind: action, thread, project, setting, choice, file,
    /// match, folder or up; empty past the end.
    pub fn kind_at(&self, row: i32) -> String {
        self.row(row)
            .map_or(String::new(), |r| r.item.kind.name().to_owned())
    }

    /// The row's entry id: a command, thread key, project key, settings
    /// path, choice id, file path, "path:line" or folder path.
    pub fn id_at(&self, row: i32) -> String {
        self.row(row).map_or(String::new(), |r| r.item.id)
    }

    /// The row's title and the description it shows.
    pub fn shown_at(&self, row: i32) -> Option<(String, String)> {
        self.row(row)
            .map(|r| (r.item.title.clone(), r.description().to_owned()))
    }

    // -- Opening and closing -------------------------------------------------

    /// Opens it in command mode with an empty query and the first entry
    /// highlighted.
    pub fn show(&mut self, engine: &Engine) {
        if !self.active {
            return;
        }
        self.open_in(engine, Mode::Command);
    }

    pub fn toggle(&mut self, engine: &Engine) {
        if self.open {
            self.dismiss(engine);
        } else {
            self.show(engine);
        }
    }

    pub fn toggle_mode(&mut self, engine: &Engine, name: &str) {
        if !self.active {
            return;
        }
        let wanted = match name {
            "files" => Mode::Files,
            "content" => Mode::Content,
            _ => Mode::Command,
        };
        if self.open && self.mode == wanted {
            self.dismiss(engine);
        } else {
            self.open_in(engine, wanted);
        }
    }

    pub fn show_menu(&mut self, engine: &Engine, command: &str) {
        if !self.active {
            return;
        }
        self.open_in(engine, Mode::Command);
        let title = Commands::of(engine)
            .rows()
            .into_iter()
            .rfind(|r| r.command == command)
            .map(|r| r.title)
            .unwrap_or_default();
        self.push_view(engine, title, Some(menu(command)));
    }

    fn browse(
        &mut self,
        engine: &Engine,
        environment_id: &str,
        add: Callback,
        options: BrowseOptions,
    ) {
        if !self.active {
            return;
        }
        self.browse_environment = environment_id.to_owned();
        self.add = Some(add);
        self.browse_options = options;
        self.open_in(engine, Mode::Browse);
    }

    fn ask(
        &mut self,
        engine: &Engine,
        title: String,
        placeholder: String,
        empty: String,
        submit: Callback,
    ) {
        if !self.active {
            return;
        }
        self.ask_title = title;
        self.ask_placeholder = placeholder;
        self.ask_empty = empty;
        self.submit = Some(submit);
        self.open_in(engine, Mode::Ask);
    }

    fn refresh_menu(&mut self, engine: &Engine) {
        if !self.open || self.mode != Mode::Command {
            return;
        }
        let Some(source) = self.views.last().and_then(|v| v.source.clone()) else {
            return;
        };
        let choices = source(engine);
        if let Some(view) = self.views.last_mut() {
            view.choices = choices;
        }
        // The highlight stays on its entry (refilter).
        self.rebuild_choices(engine);
    }

    fn open_in(&mut self, engine: &Engine, mode: Mode) {
        self.open = true;
        self.views.clear();
        self.entries.clear();
        self.error.clear();
        self.invalid_regex = false;
        self.truncated = false;
        self.message_matches.clear();
        self.message_query.clear();
        self.browse_query.clear();
        self.browse_parent.clear();
        self.browse_entries.clear();
        self.generation += 1;
        self.pending = 0;
        self.stop_timer(engine);
        self.mode = mode;
        self.query = if mode == Mode::Browse {
            self.browse_options.query.clone()
        } else {
            String::new()
        };
        self.target = target(engine);
        self.rebuild(engine);
        // A browsed path is added with Enter unless a folder is highlighted.
        self.set_highlighted(if mode == Mode::Browse { -1 } else { 0 });
        if mode != Mode::Command && mode != Mode::Ask {
            self.schedule_search(engine);
        }
    }

    /// Closes it without running anything; the composer gets the keyboard
    /// back.
    pub fn dismiss(&mut self, engine: &Engine) {
        self.close(engine, true);
    }

    /// Escape: a secondary mode goes back to command mode, a submenu to the
    /// root, anything else dismisses.
    pub fn back(&mut self, engine: &Engine) {
        if !self.open {
            return;
        }
        if self.mode != Mode::Command {
            self.open_in(engine, Mode::Command);
        } else if !self.views.is_empty() {
            self.views.clear();
            self.query.clear();
            self.rebuild(engine);
            self.set_highlighted(0);
        } else {
            self.dismiss(engine);
        }
    }

    /// Backspace on an empty query leaves a submenu; false when there is
    /// none.
    pub fn leave_submenu(&mut self, engine: &Engine) -> bool {
        if !self.open || self.views.is_empty() || !self.query.is_empty() {
            return false;
        }
        self.views.pop();
        self.rebuild(engine);
        self.set_highlighted(0);
        true
    }

    fn close(&mut self, engine: &Engine, return_focus: bool) {
        if !self.open {
            return;
        }
        self.open = false;
        self.views.clear();
        self.generation += 1;
        self.pending = 0;
        self.stop_timer(engine);
        self.mode = Mode::Command;
        if return_focus {
            self.bridge
                .send_to_bricks(engine, "composer.focus", &Json::Null);
        }
    }

    fn push_view(&mut self, engine: &Engine, title: String, source: Option<Choices>) {
        let choices = source.as_ref().map_or_else(Vec::new, |s| s(engine));
        self.views.push(View {
            title,
            choices,
            source,
        });
        self.query.clear();
        self.rebuild(engine);
        // The one in effect is where the highlight starts.
        let current = self
            .views
            .last()
            .and_then(|v| v.choices.iter().position(|c| c.current))
            .unwrap_or(0);
        self.set_highlighted(i32::try_from(current).unwrap_or(0));
    }

    // -- Typing and choosing -------------------------------------------------

    pub fn set_query(&mut self, engine: &Engine, query: &str) {
        if query == self.query {
            return;
        }
        self.query = query.to_owned();
        if !self.open {
            return;
        }
        match self.mode {
            Mode::Command => {
                self.refilter(engine, false);
                // Messages are searched from two characters on, never for
                // actions.
                if self.views.is_empty()
                    && !query.starts_with('>')
                    && normalize(query).chars().count() >= 2
                {
                    self.schedule_search(engine);
                } else if self.timer.is_some() || self.pending > 0 || !self.message_query.is_empty()
                {
                    self.generation += 1;
                    self.pending = 0;
                    self.stop_timer(engine);
                    self.search_messages(engine, self.generation);
                }
                self.set_highlighted(0);
            }
            Mode::Ask => {}
            mode => {
                self.schedule_search(engine);
                if mode == Mode::Browse {
                    self.set_highlighted(-1);
                }
            }
        }
    }

    pub fn set_case_sensitive(&mut self, engine: &Engine, on: bool) {
        if std::mem::replace(&mut self.case_sensitive, on) != on {
            self.options_changed(engine);
        }
    }

    pub fn set_whole_word(&mut self, engine: &Engine, on: bool) {
        if std::mem::replace(&mut self.whole_word, on) != on {
            self.options_changed(engine);
        }
    }

    pub fn set_use_regex(&mut self, engine: &Engine, on: bool) {
        if std::mem::replace(&mut self.use_regex, on) != on {
            self.options_changed(engine);
        }
    }

    fn options_changed(&mut self, engine: &Engine) {
        if self.open && self.mode == Mode::Content {
            self.schedule_search(engine);
        }
    }

    pub fn set_highlighted(&mut self, row: i32) {
        // Browse mode leaves nothing highlighted until the user moves.
        let lowest = if self.mode == Mode::Browse { -1 } else { 0 };
        let count = self.count();
        self.highlighted = if count == 0 {
            lowest
        } else {
            row.clamp(lowest, count - 1)
        };
    }

    /// Moves the highlight by `delta` rows, wrapping around.
    pub fn move_by(&mut self, delta: i32) {
        let count = self.count();
        if count == 0 {
            return;
        }
        if self.highlighted < 0 {
            self.set_highlighted(if delta > 0 { 0 } else { count - 1 });
            return;
        }
        let next = (i64::from(self.highlighted) + i64::from(delta)).rem_euclid(i64::from(count));
        self.set_highlighted(i32::try_from(next).unwrap_or(0));
    }

    /// Enter: the highlighted entry, or in browse mode with none, hands the
    /// path on.
    pub fn run_highlighted(&mut self, engine: &Engine) -> bool {
        if self.open && self.mode == Mode::Ask {
            let text = self.query.trim().to_owned();
            let Some(submit) = self.submit.clone().filter(|_| !text.is_empty()) else {
                return false;
            };
            self.bridge
                .defer(engine, move |engine| submit(engine, &text));
            return true;
        }
        if self.mode == Mode::Browse && (self.highlighted < 0 || self.highlighted >= self.count()) {
            // Enter with nothing highlighted adds the path typed.
            let path = self.browsed_path();
            if self.relative_without_project(engine) || self.add.is_none() || path.is_empty() {
                return false;
            }
            self.hand_on(engine, path);
            return true;
        }
        self.run(engine, self.highlighted)
    }

    /// Gives `path` to the browser: the palette stays when it asked so, for
    /// another try until it finishes.
    fn hand_on(&mut self, engine: &Engine, path: String) {
        let add = if self.browse_options.keep_open {
            self.add.clone()
        } else {
            let add = self.add.take();
            self.close(engine, false);
            add
        };
        if let Some(add) = add {
            self.bridge.defer(engine, move |engine| add(engine, &path));
        }
    }

    /// A path that is not absolute is under the folder of the project the
    /// window shows; without one there is nowhere for it to be.
    fn relative_without_project(&self, engine: &Engine) -> bool {
        let query = self.query.trim();
        self.mode == Mode::Browse
            && !query.is_empty()
            && !query.starts_with('/')
            && !query.starts_with('~')
            && target(engine).root.is_empty()
    }

    fn folder_highlighted(&self) -> bool {
        self.mode == Mode::Browse
            && self
                .row(self.highlighted)
                .is_some_and(|r| r.item.kind == Kind::Folder)
    }

    /// "Create & Add" only when the folder's own answer says it is not
    /// there; before the answer, or while a folder is highlighted, the plain
    /// verb.
    fn submit_label(&self, engine: &Engine) -> String {
        if !self.open
            || self.mode != Mode::Browse
            || self.add.is_none()
            || self.relative_without_project(engine)
            || self.browsed_path().is_empty()
        {
            return String::new();
        }
        let verb = &self.browse_options.submit;
        let query = self.query.trim();
        let mut missing = false;
        if !self.folder_highlighted() && self.browse_query == query {
            missing = if query.ends_with('/') {
                !self.error.is_empty()
            } else {
                let leaf = name_of(query);
                !self.browse_entries.iter().any(|f| text(f, "name") == leaf)
            };
        }
        if missing {
            format!("Create & {verb}")
        } else {
            verb.clone()
        }
    }

    fn submit_shortcut(&self, engine: &Engine, label: &str) -> String {
        if label.is_empty() {
            return String::new();
        }
        // The platform's own name for the key: Command on macOS.
        let key = if self.folder_highlighted() {
            "mod+enter"
        } else {
            "enter"
        };
        Keymap::of(engine).key_label(key)
    }

    /// Hands on the highlighted folder, else the path typed (browse mode's
    /// mod+Enter).
    pub fn add_browsed_folder(&mut self, engine: &Engine) -> bool {
        if !self.open
            || self.mode != Mode::Browse
            || self.add.is_none()
            || self.relative_without_project(engine)
        {
            return false;
        }
        let path = match self.row(self.highlighted) {
            Some(row) if row.item.kind == Kind::Folder => row.item.id,
            _ => self.browsed_path(),
        };
        if path.is_empty() {
            return false;
        }
        self.hand_on(engine, path);
        true
    }

    /// Runs the entry at `row` (a submenu or a folder moves the palette on;
    /// anything else closes it first); false when there is none.
    pub fn run(&mut self, engine: &Engine, row: i32) -> bool {
        if !self.open {
            return false;
        }
        let Some(row) = self.row(row) else {
            return false;
        };
        let entry = row.item;
        if !entry.enabled {
            return false;
        }
        // What moves the palette on keeps it open.
        match entry.kind {
            Kind::Action if Commands::of(engine).is_menu(&entry.id) => {
                self.push_view(engine, entry.title.clone(), Some(menu(&entry.id)));
                return true;
            }
            Kind::Choice => {
                let choice = self
                    .views
                    .last()
                    .and_then(|v| v.choices.get(row.entry))
                    .cloned();
                let Some(choice) = choice else {
                    self.close(engine, false);
                    return true;
                };
                if let Some(submenu) = choice.submenu {
                    self.push_view(engine, choice.title, Some(submenu));
                    return true;
                }
                if !choice.keep_open {
                    self.close(engine, false);
                }
                if let Some(run) = choice.run {
                    self.bridge.defer(engine, move |engine| run(engine));
                }
                return true;
            }
            Kind::Folder => {
                let cut = self.query.rfind('/').map_or(0, |slash| slash + 1);
                let chosen = format!("{}{}", &self.query[..cut], entry.title);
                // A pinned name follows the folder in, unless the folder is it.
                let pinned = &self.browse_options.pinned;
                let next = if pinned.is_empty() {
                    format!("{chosen}/")
                } else if &entry.title == pinned {
                    chosen
                } else {
                    format!("{chosen}/{pinned}")
                };
                self.set_query(engine, &next);
                self.set_highlighted(-1);
                return true;
            }
            Kind::Up => {
                let next = format!("{}{}", entry.id, self.browse_options.pinned);
                self.set_query(engine, &next);
                self.set_highlighted(-1);
                return true;
            }
            _ => {}
        }
        // Closed first: what the entry opens takes the keyboard.
        self.close(engine, false);
        self.open_entry(engine, &entry)
    }

    fn run_command(&mut self, engine: &Engine, command: &str) -> bool {
        self.running = Some(command.to_owned());
        let ran = Commands::of(engine).run(engine, command);
        // The command runs once the palette is done; whether it failed is
        // known right after.
        self.bridge.defer(engine, |engine| {
            controller::with::<Palette, _>(engine, |c, _| c.running = None);
        });
        ran
    }

    fn open_entry(&mut self, engine: &Engine, entry: &Entry) -> bool {
        let navigate = |route: Route| {
            controller::with::<Navigation, _>(engine, move |n, engine| n.open(engine, route));
        };
        match entry.kind {
            Kind::Action => self.run_command(engine, &entry.id),
            Kind::Thread => {
                if !store::with(engine, |s| s.thread(&entry.id).is_some()) {
                    return false;
                }
                if navigation::shown(engine) != Route::Thread(entry.id.clone()) {
                    navigate(Route::Thread(entry.id.clone()));
                }
                true
            }
            Kind::Project => {
                // Its latest thread, or a new one in it.
                let Some(group) = sidebar::group(engine, &entry.id) else {
                    return false;
                };
                let members: HashSet<&str> = group.member_keys.iter().map(String::as_str).collect();
                let latest = store::with(engine, |s| {
                    let mut latest: Option<(i64, String)> = None;
                    for thread in s.threads() {
                        if thread.archived_at.is_some() || thread.subagent {
                            continue;
                        }
                        let project = format!("{}:{}", thread.environment_id, thread.project_id);
                        if !members.contains(project.as_str()) {
                            continue;
                        }
                        let at = recency(&thread);
                        if latest.as_ref().is_none_or(|(was, _)| at > *was) {
                            latest = Some((at, thread.key()));
                        }
                    }
                    latest
                });
                match latest {
                    Some((_, key)) => navigate(Route::Thread(key)),
                    None => drafts::start_in(engine, &group),
                }
                true
            }
            Kind::Setting => {
                // "<section>#<setting>" opens the section at that setting,
                // and "<section>?<command>" a command's keybindings.
                match entry.id.find(['#', '?']) {
                    Some(mark) if entry.id[mark..].starts_with('#') => {
                        self.bridge.dispatch(
                            engine,
                            "settings.openResult",
                            json!({"to": &entry.id[..mark], "targetId": &entry.id[mark + 1..]}),
                        );
                    }
                    Some(mark) => navigate(Route::Settings(entry.id[..mark].to_owned())),
                    None => navigate(Route::Settings(entry.id.clone())),
                }
                true
            }
            Kind::File => {
                let options = json!({"path": entry.id});
                controller::with::<RightPanel, _>(engine, |p, engine| {
                    p.open(engine, "files", &options);
                });
                true
            }
            Kind::Match => {
                let (path, line) = entry.id.rsplit_once(':').unwrap_or((&entry.id, ""));
                let options = json!({"path": path, "line": line.parse::<i64>().unwrap_or(0)});
                controller::with::<RightPanel, _>(engine, |p, engine| {
                    p.open(engine, "files", &options);
                });
                true
            }
            _ => false,
        }
    }

    /// The settings sections to offer: [{to, label, keywords, requires,
    /// targetId, detail}].
    pub fn set_settings_sections(&mut self, engine: &Engine, sections: Vec<Json>) {
        // A section that needs shell state is listed once it is there.
        for section in &sections {
            let needs = text(section, "requires");
            if needs.is_empty() || !self.requires.insert(needs.to_owned()) {
                continue;
            }
            let key = needs.to_owned();
            self.bridge.watch(engine, needs, move |engine, _| {
                let key = key.clone();
                later(engine, move |c, engine| {
                    if c.settings_sections
                        .iter()
                        .any(|s| text(s, "requires") == key)
                    {
                        c.rebuild(engine);
                    }
                });
            });
        }
        self.settings_sections = sections;
        self.rebuild(engine);
    }

    // -- What it lists -------------------------------------------------------

    /// Reads what the palette lists again, while it is open.
    fn rebuild(&mut self, engine: &Engine) {
        if !self.open {
            return;
        }
        if self.mode != Mode::Command {
            // Found entries come from the MC (none yet when it just opened);
            // the rows follow them, and the empty text may change.
            self.refilter(engine, true);
        } else if self.views.is_empty() {
            self.rebuild_command(engine);
        } else {
            self.rebuild_choices(engine);
        }
    }

    fn rebuild_choices(&mut self, engine: &Engine) {
        let choices = self.views.last().map_or(&[][..], |v| &v.choices[..]);
        let entries = choices
            .iter()
            .map(|choice| {
                let mut terms = vec![normalize(&choice.title), normalize(&choice.description)];
                terms.extend(choice.terms.iter().map(|t| normalize(t)));
                let mut entry = Entry::new(Kind::Choice, &choice.id, &choice.title)
                    .described(&choice.description)
                    .found_by(terms);
                entry.enabled = choice.enabled;
                entry.current = choice.current;
                entry
            })
            .collect();
        self.entries = with_haystacks(entries);
        self.refilter(engine, true);
    }

    fn rebuild_command(&mut self, engine: &Engine) {
        let commands = Commands::of(engine);
        let mut entries: Vec<Entry> = Vec::new();
        for row in commands.rows() {
            if row.command == TOGGLE || row.command.starts_with("thread.jump.") || !row.listed {
                continue;
            }
            let mut terms = vec![normalize(&row.title), normalize(&row.command)];
            terms.extend(commands.terms(&row.command).iter().map(|t| normalize(t)));
            let mut entry = Entry::new(Kind::Action, &row.command, &row.title)
                .described(&row.description)
                .found_by(terms);
            entry.shortcut = row.shortcut;
            entry.enabled = row.enabled;
            entries.push(entry);
        }

        let current = match navigation::shown(engine) {
            Route::Thread(key) => key,
            _ => String::new(),
        };
        let mut threads = store::with(engine, |s| {
            let mut threads = Vec::new();
            for thread in s.threads() {
                if thread.subagent {
                    continue;
                }
                let key = thread.key();
                let pull_requests: Vec<String> = pull_request_terms(s.thread_row(&key))
                    .iter()
                    .map(|t| normalize(t))
                    .collect();
                // An archived thread is only found by a pull request linked
                // to it.
                if thread.archived_at.is_some() && pull_requests.is_empty() {
                    continue;
                }
                let project =
                    s.project(&format!("{}:{}", thread.environment_id, thread.project_id));
                let mut description = Vec::new();
                if let Some(project) = &project {
                    description.push(project.title.clone());
                }
                if let Some(branch) = &thread.branch {
                    description.push(format!("#{branch}"));
                }
                if key == current {
                    description.push("Current thread".to_owned());
                }
                let terms = if thread.archived_at.is_some() {
                    pull_requests.clone()
                } else {
                    let mut terms = vec![normalize(&thread.title)];
                    terms.extend(pull_requests.iter().cloned());
                    // Last, so a pasted id never outranks a title.
                    terms.push(normalize(project.as_ref().map_or("", |p| &p.title)));
                    terms.push(normalize(thread.branch.as_deref().unwrap_or_default()));
                    terms.push(normalize(&thread.id));
                    terms
                };
                let mut entry = Entry::new(Kind::Thread, &key, &thread.title)
                    .described(description.join(" · "))
                    .found_by(terms);
                entry.recency = recency(&thread);
                entry.pull_requests = simplified(&pull_requests.join(" "));
                entry.archived = thread.archived_at.is_some();
                threads.push(entry);
            }
            threads
        });
        threads.sort_by_key(|t| std::cmp::Reverse(t.recency));
        entries.append(&mut threads);

        for group in sidebar::groups(engine) {
            let name = text_of(&group.summary, "displayName");
            let mut terms = vec![normalize(&name)];
            for member in &group.members {
                terms.push(normalize(&member.title));
                terms.push(normalize(&member.workspace_root));
            }
            entries.push(
                Entry::new(Kind::Project, &group.key, &name)
                    .described(text_of(&group.summary, "workspaceRoot"))
                    .found_by(terms),
            );
        }

        for section in &self.settings_sections {
            // A section that needs shell state is listed once it is there
            // (settingsPages.js navRows).
            let needs = text(section, "requires");
            if !needs.is_empty()
                && self
                    .bridge
                    .published(engine, needs)
                    .is_none_or(|v| v.is_null())
            {
                continue;
            }
            let label = text(section, "label");
            // A setting on the section's page is found by its own title, and
            // opens there.
            let target = text(section, "targetId");
            let to = text(section, "to");
            let id = if target.is_empty() {
                to.to_owned()
            } else {
                format!("{to}#{target}")
            };
            let description = if target.is_empty() {
                "Settings"
            } else {
                text(section, "detail")
            };
            entries.push(
                Entry::new(Kind::Setting, id, label)
                    .described(description)
                    .found_by(vec![normalize(label), normalize(text(section, "keywords"))]),
            );
        }

        // Each keybinding command, after the settings it mirrors: found by
        // its label, id and keys.
        let mut shortcuts: HashMap<String, usize> = HashMap::new();
        for binding in Keymap::of(engine).rows() {
            let command = text(&binding, "command");
            let at = *shortcuts.entry(command.to_owned()).or_insert_with(|| {
                let label = text(&binding, "label");
                let mut entry = Entry::new(
                    Kind::Setting,
                    format!("{KEYBINDINGS_SECTION}?{command}"),
                    label,
                )
                .described("Keybindings")
                .found_by(vec![normalize(label), normalize(command)]);
                entry.secondary = true;
                entries.push(entry);
                entries.len() - 1
            });
            entries[at].terms.push(normalize(text(&binding, "key")));
        }

        self.entries = with_haystacks(entries);
        self.refilter(engine, true);
    }

    /// Filters to the query and moves only the rows that changed;
    /// `refreshed` says the entries themselves may have changed.
    fn refilter(&mut self, engine: &Engine, refreshed: bool) {
        let mut next: Vec<Row> = Vec::new();
        let entries = &self.entries;
        let mut add = |group: &str, entry: usize, description: String| {
            let item = entries[entry].clone();
            next.push(Row {
                group: group.to_owned(),
                entry,
                key: format!("{group}\n{}", item.id),
                description,
                item,
                row_key: 0,
            });
        };

        if self.mode != Mode::Command {
            // The MC filtered them already.
            for (index, entry) in entries.iter().enumerate() {
                add(&entry.group, index, String::new());
            }
            self.apply(engine, next, refreshed);
            return;
        }

        let actions_only = self.views.is_empty() && self.query.starts_with('>');
        let query = normalize(if actions_only {
            &self.query[1..]
        } else {
            &self.query
        });
        let tokens: Vec<&str> = query.split(' ').filter(|t| !t.is_empty()).collect();

        if !self.views.is_empty() {
            let mut matches: Vec<(usize, i32)> = entries
                .iter()
                .enumerate()
                .filter(|(_, e)| query.is_empty() || has_all(&e.haystack, &tokens))
                .map(|(index, e)| {
                    let rank = if query.is_empty() {
                        0
                    } else {
                        rank(&e.terms, &query, &tokens)
                    };
                    (index, rank)
                })
                .collect();
            matches.sort_by_key(|m| std::cmp::Reverse(m.1));
            for (index, _) in matches {
                add("", index, String::new());
            }
            self.apply(engine, next, refreshed);
            return;
        }

        if query.is_empty() {
            // The hand-picked actions, in order, then recent threads.
            for command in ROOT_COMMANDS {
                for (index, entry) in entries.iter().enumerate() {
                    if entry.kind == Kind::Action && entry.id == command {
                        add(ACTIONS, index, String::new());
                    }
                }
            }
            if !actions_only {
                let recent = entries
                    .iter()
                    .enumerate()
                    .filter(|(_, e)| e.kind == Kind::Thread && !e.archived)
                    .take(RECENT_THREADS);
                for (index, _) in recent {
                    add("Recent Threads", index, String::new());
                }
            }
            self.apply(engine, next, refreshed);
            return;
        }

        struct Match {
            entry: usize,
            rank: i32,
            tiebreak: i32,
        }
        const LABELS: [&str; 4] = [ACTIONS, "Projects", "Settings", "Threads"];
        let group_of = |kind: Kind| match kind {
            Kind::Action => 0,
            Kind::Project => 1,
            Kind::Setting => 2,
            _ => 3,
        };
        // Threads found by their messages count only for the query they
        // answer.
        let messages_count = !self.message_query.is_empty() && self.message_query == query;
        let mut by_group: [Vec<Match>; 4] = Default::default();
        let mut snippets: HashMap<usize, String> = HashMap::new();
        for (index, entry) in entries.iter().enumerate() {
            if actions_only && entry.kind != Kind::Action {
                continue;
            }
            let group = group_of(entry.kind);
            if has_all(&entry.haystack, &tokens) {
                let tiebreak = if entry.kind == Kind::Setting {
                    settings_rank(&entry.terms, &query, &tokens)
                } else {
                    0
                };
                by_group[group].push(Match {
                    entry: index,
                    rank: rank(&entry.terms, &query, &tokens),
                    tiebreak,
                });
                // Found by its pull request: say how the thread belongs to it.
                if entry.kind == Kind::Thread
                    && !entry.pull_requests.is_empty()
                    && has_all(&entry.pull_requests, &tokens)
                {
                    let how = if entry.archived {
                        "Archived thread"
                    } else {
                        "Linked thread"
                    };
                    snippets.insert(index, how.to_owned());
                }
            } else if entry.kind == Kind::Thread
                && messages_count
                && let Some(snippet) = self.message_matches.get(&entry.id)
            {
                by_group[group].push(Match {
                    entry: index,
                    rank: 0,
                    tiebreak: 0,
                });
                snippets.insert(index, snippet.clone());
            }
        }
        for (group, mut matches) in by_group.into_iter().enumerate() {
            matches.sort_by(|a, b| {
                let (left, right) = (&entries[a.entry], &entries[b.entry]);
                left.secondary
                    .cmp(&right.secondary)
                    .then(b.rank.cmp(&a.rank))
                    .then(b.tiebreak.cmp(&a.tiebreak))
                    .then(right.recency.cmp(&left.recency))
            });
            for m in matches {
                add(
                    LABELS[group],
                    m.entry,
                    snippets.remove(&m.entry).unwrap_or_default(),
                );
            }
        }
        self.apply(engine, next, refreshed);
    }

    fn apply(&mut self, engine: &Engine, mut next: Vec<Row>, refreshed: bool) {
        let signals = self.list.signals.borrow().clone();
        let after = next.len();
        // Only the rows between the unchanged head and tail move.
        let (highlighted_key, before, head, tail, changed) = {
            let rows = self.list.rows.borrow();
            // A background update keeps the highlight on its entry.
            let highlighted_key = usize::try_from(self.highlighted)
                .ok()
                .and_then(|i| rows.get(i))
                .map(|r| r.key.clone());
            let before = rows.len();
            let mut head = 0;
            while head < before && head < after && rows[head].key == next[head].key {
                head += 1;
            }
            let mut tail = 0;
            while tail < before - head
                && tail < after - head
                && rows[before - 1 - tail].key == next[after - 1 - tail].key
            {
                tail += 1;
            }
            // The rows that stay keep their view keys; those that show
            // something else now, by their index after.
            let mut changed: Option<(usize, usize)> = None;
            let kept = (0..head).chain(after - tail..after);
            for row in kept {
                let was = &rows[if row < head {
                    row
                } else {
                    row + before - after
                }];
                next[row].row_key = was.row_key;
                if was.shows() != next[row].shows() {
                    changed = Some(changed.map_or((row, row), |(first, _)| (first, row)));
                }
            }
            (highlighted_key, before, head, tail, changed)
        };
        for row in &mut next[head..after - tail] {
            row.row_key = self.list.fresh_key();
        }
        if before - tail > head {
            let count = before - tail - head;
            if let Some(s) = &signals {
                s.rows_about_to_be_removed(engine, head, count);
            }
            self.list.rows.borrow_mut().drain(head..head + count);
            if let Some(s) = &signals {
                s.rows_removed(engine, head, count);
            }
        }
        if after - tail > head {
            let count = after - tail - head;
            if let Some(s) = &signals {
                s.rows_about_to_be_inserted(engine, head, count);
            }
            let inserted = next[head..head + count].iter().cloned();
            self.list.rows.borrow_mut().splice(head..head, inserted);
            if let Some(s) = &signals {
                s.rows_inserted(engine, head, count);
            }
        }
        *self.list.rows.borrow_mut() = next;
        if let (Some((first, last)), Some(s)) = (changed, &signals) {
            s.data_changed(engine, first, last - first + 1, &[]);
        }
        let found = highlighted_key
            .filter(|_| refreshed)
            .map(|key| self.list.rows.borrow().iter().position(|r| r.key == key));
        match found {
            Some(Some(at)) => self.set_highlighted(i32::try_from(at).unwrap_or(0)),
            _ => self.set_highlighted(self.highlighted),
        }
    }

    // -- Searching the MC ----------------------------------------------------

    /// Another thread's files are another search: what was found goes.
    fn follow_target(&mut self, engine: &Engine) {
        if !self.active {
            return;
        }
        let next = target(engine);
        if next == self.target {
            return;
        }
        self.target = next;
        if !self.open || !matches!(self.mode, Mode::Files | Mode::Content) {
            return;
        }
        // Another project's search starts afresh.
        self.query.clear();
        self.entries.clear();
        self.error.clear();
        self.truncated = false;
        self.invalid_regex = false;
        self.refilter(engine, true);
        self.schedule_search(engine);
    }

    fn stop_timer(&mut self, engine: &Engine) {
        if let Some(timer) = self.timer.take() {
            engine.cancel_call(timer);
        }
    }

    /// Starts the mode's search against the MC once typing pauses.
    fn schedule_search(&mut self, engine: &Engine) {
        // An answer for an older query no longer counts.
        self.generation += 1;
        self.pending = 0;
        self.stop_timer(engine);
        let at = engine.now() + Duration::from_millis(SEARCH_DELAY_MS);
        self.timer = Some(engine.call_at(at, |engine| {
            later(engine, |c, engine| {
                c.timer = None;
                c.search(engine);
            });
        }));
    }

    fn search(&mut self, engine: &Engine) {
        if !self.open {
            return;
        }
        let generation = self.generation;
        match self.mode {
            Mode::Files => self.search_files(engine, generation),
            Mode::Content => self.search_content(engine, generation),
            Mode::Browse => self.search_folders(engine, generation),
            _ => self.search_messages(engine, generation),
        }
    }

    fn target_online(&self, engine: &Engine) -> bool {
        let env = &self.target.environment_id;
        !env.is_empty() && store::with(engine, |s| s.environment_online(env))
    }

    /// Asks the MC of `environment`; `found` hears the answer once no
    /// controller is running.
    fn ask_mc(
        &self,
        environment: &str,
        method: &str,
        payload: Json,
        found: impl FnOnce(&mut Palette, &Engine, Result<Json, McError>) + 'static,
    ) {
        self.mc.call(
            environment,
            method,
            payload,
            Box::new(move |engine, result| {
                later(engine, move |c, engine| found(c, engine, result));
            }),
        );
    }

    fn search_files(&mut self, engine: &Engine, generation: u64) {
        if !self.target_online(engine) {
            self.entries.clear();
            self.refilter(engine, true);
            return;
        }
        self.pending += 1;
        let payload = json!({
            "cwd": self.target.root,
            "query": self.query.trim(),
            "limit": FILE_LIMIT,
            "kind": "file",
        });
        self.ask_mc(
            &self.target.environment_id,
            "projects.searchEntries",
            payload,
            move |c, engine, result| {
                if generation != c.generation || c.mode != Mode::Files {
                    return;
                }
                c.pending = 0;
                let (answer, error) = split(result);
                c.entries = answer["entries"]
                    .as_array()
                    .map(Vec::as_slice)
                    .unwrap_or_default()
                    .iter()
                    .map(|found| {
                        let path = text(found, "path");
                        Entry::new(Kind::File, path, name_of(path)).described(directory_of(path))
                    })
                    .collect();
                c.error = error;
                c.refilter(engine, true);
                c.set_highlighted(0);
            },
        );
    }

    fn search_content(&mut self, engine: &Engine, generation: u64) {
        if self.query.trim().is_empty() || !self.target_online(engine) {
            self.entries.clear();
            self.error.clear();
            self.truncated = false;
            self.invalid_regex = false;
            self.refilter(engine, true);
            return;
        }
        self.pending += 1;
        let payload = json!({
            "cwd": self.target.root,
            "query": self.query,
            "limit": CONTENT_LIMIT,
            "caseSensitive": self.case_sensitive,
            "wholeWord": self.whole_word,
            "useRegex": self.use_regex,
        });
        self.ask_mc(
            &self.target.environment_id,
            "projects.searchContents",
            payload,
            move |c, engine, result| {
                if generation != c.generation || c.mode != Mode::Content {
                    return;
                }
                c.pending = 0;
                let (answer, error) = split(result);
                // Grouped by file, in the order the MC found them.
                let mut by_file: Vec<(String, Vec<Entry>)> = Vec::new();
                for found in answer["matches"]
                    .as_array()
                    .map(Vec::as_slice)
                    .unwrap_or_default()
                {
                    let path = text(found, "path");
                    let line = found["lineNumber"].as_i64().unwrap_or(0);
                    let mut entry = Entry::new(
                        Kind::Match,
                        format!("{path}:{line}"),
                        text(found, "lineContent").trim(),
                    )
                    .described(line.to_string());
                    entry.group = path.to_owned();
                    match by_file.iter_mut().find(|(p, _)| p == path) {
                        Some((_, entries)) => entries.push(entry),
                        None => by_file.push((path.to_owned(), vec![entry])),
                    }
                }
                c.error = error;
                c.truncated = answer["truncated"].as_bool().unwrap_or(false);
                c.invalid_regex = answer.get("regexFallbackError").is_some();
                c.entries = by_file.into_iter().flat_map(|(_, e)| e).collect();
                c.refilter(engine, true);
                c.set_highlighted(0);
            },
        );
    }

    fn search_messages(&mut self, engine: &Engine, generation: u64) {
        let query = normalize(if self.query.starts_with('>') {
            ""
        } else {
            &self.query
        });
        if query.chars().count() < 2 || !self.views.is_empty() {
            if !self.message_query.is_empty() {
                self.message_query.clear();
                self.message_matches.clear();
                self.refilter(engine, true);
            }
            return;
        }
        // Each MC answers for its own threads.
        let online: Vec<String> = store::with(engine, |s| {
            s.environments()
                .into_iter()
                .filter(|e| s.environment_online(e))
                .collect()
        });
        if online.is_empty() {
            return;
        }
        self.message_query = query;
        self.message_matches.clear();
        self.pending = online.len();
        let raw: String = self.query.trim().chars().take(200).collect();
        for environment in online {
            let payload = json!({"query": raw, "limit": MESSAGE_LIMIT});
            let env = environment.clone();
            self.ask_mc(
                &environment,
                "orchestration.searchThreads",
                payload,
                move |c, engine, result| {
                    if generation != c.generation || c.mode != Mode::Command {
                        return;
                    }
                    c.pending = c.pending.saturating_sub(1);
                    if let Ok(answer) = result {
                        for found in answer["matches"]
                            .as_array()
                            .map(Vec::as_slice)
                            .unwrap_or_default()
                        {
                            let key = format!("{env}:{}", text(found, "threadId"));
                            c.message_matches
                                .entry(key)
                                .or_insert_with(|| text(found, "snippet").to_owned());
                        }
                    }
                    c.refilter(engine, true);
                },
            );
        }
    }

    fn search_folders(&mut self, engine: &Engine, generation: u64) {
        let query = self.query.trim().to_owned();
        if query.is_empty() || self.browse_environment.is_empty() {
            self.entries.clear();
            self.browse_parent.clear();
            self.browse_entries.clear();
            self.refilter(engine, true);
            return;
        }
        if !store::with(engine, |s| s.environment_online(&self.browse_environment)) {
            self.error = "The environment is not connected.".into();
            self.entries.clear();
            self.refilter(engine, true);
            return;
        }
        if self.relative_without_project(engine) {
            self.error.clear();
            self.entries.clear();
            self.browse_entries.clear();
            self.refilter(engine, true);
            return;
        }
        // With a pinned name the whole folder is listed and filtered here,
        // as the web does: a leaf that is the pinned name hides nothing.
        let pinned = self.browse_options.pinned.clone();
        let slash = query.rfind('/');
        let asked = match slash {
            Some(slash) if !pinned.is_empty() => query[..=slash].to_owned(),
            _ => query.clone(),
        };
        let leaf = match slash {
            Some(slash) if asked != query => query[slash + 1..].to_owned(),
            _ => String::new(),
        };
        let filter = if leaf == pinned { String::new() } else { leaf };
        let relative = !asked.starts_with('/') && !asked.starts_with('~');
        // A relative path is under the shown project's folder (the
        // contract's cwd).
        let payload = if relative {
            json!({"partialPath": asked, "cwd": target(engine).root})
        } else {
            json!({"partialPath": asked})
        };
        self.pending += 1;
        let environment = self.browse_environment.clone();
        self.ask_mc(
            &environment,
            "filesystem.browse",
            payload,
            move |c, engine, result| {
                if generation != c.generation || c.mode != Mode::Browse {
                    return;
                }
                c.pending = 0;
                let (answer, error) = split(result);
                c.error = error;
                c.browse_query = query.clone();
                c.browse_parent = text(&answer, "parentPath").to_owned();
                c.browse_entries = answer["entries"].as_array().cloned().unwrap_or_default();
                let mut entries = Vec::new();
                // Up from a whole folder, to its parent.
                if asked.ends_with('/') && !c.browse_parent.is_empty() && c.browse_parent != "/" {
                    let mut up = parent_of(&c.browse_parent);
                    if !up.ends_with('/') {
                        up.push('/');
                    }
                    let mut entry = Entry::new(Kind::Up, up, "..");
                    entry.group = DIRECTORIES.into();
                    entries.push(entry);
                }
                let filter_lower = filter.to_lowercase();
                for folder in &c.browse_entries {
                    let name = text(folder, "name");
                    if asked != query
                        && (!name.to_lowercase().starts_with(&filter_lower)
                            || (name.starts_with('.') && !filter.starts_with('.')))
                    {
                        continue;
                    }
                    let mut entry = Entry::new(Kind::Folder, text(folder, "fullPath"), name);
                    entry.group = DIRECTORIES.into();
                    entries.push(entry);
                }
                c.entries = entries;
                c.refilter(engine, true);
            },
        );
    }

    /// The resolved path: a whole folder is the browsed parent; a named one
    /// is the folder of that name when it exists; anything else, as typed.
    fn browsed_path(&self) -> String {
        let query = self.query.trim();
        if query.is_empty() {
            return String::new();
        }
        // An answer for another path says nothing about this one.
        if self.browse_query != query {
            return query.to_owned();
        }
        if query.ends_with('/') {
            return if self.browse_parent.is_empty() {
                query.to_owned()
            } else {
                self.browse_parent.clone()
            };
        }
        let leaf = name_of(query);
        self.browse_entries
            .iter()
            .find(|f| text(f, "name") == leaf)
            .map_or_else(|| query.to_owned(), |f| text(f, "fullPath").to_owned())
    }

    // -- What PaletteModel shows ---------------------------------------------

    fn submenu(&self) -> String {
        if self.mode == Mode::Ask {
            return self.ask_title.clone();
        }
        self.views.last().map_or(String::new(), |v| v.title.clone())
    }

    pub fn placeholder(&self, engine: &Engine) -> String {
        match self.mode {
            Mode::Files => "Search files…".into(),
            Mode::Content => {
                let project = match navigation::shown(engine) {
                    Route::Thread(key) => store::with(engine, |s| {
                        s.thread(&key).and_then(|t| {
                            s.project(&format!("{}:{}", t.environment_id, t.project_id))
                        })
                    }),
                    _ => None,
                };
                project.map_or_else(
                    || "Search in project".into(),
                    |p| format!("Search in {}", p.title),
                )
            }
            Mode::Browse => "Enter project path (e.g. ~/projects/my-app)".into(),
            Mode::Ask => self.ask_placeholder.clone(),
            Mode::Command if self.views.is_empty() => {
                "Search commands, projects, and threads...".into()
            }
            Mode::Command => "Search...".into(),
        }
    }

    /// What the palette says when nothing is listed, or empty.
    fn empty_text(&self, engine: &Engine) -> String {
        if self.count() > 0 {
            return String::new();
        }
        let has_query = !self.query.trim().is_empty();
        match self.mode {
            Mode::Files if !self.target_online(engine) => {
                "Open a project to search its files.".into()
            }
            Mode::Files if self.searching() => "Searching workspace files…".into(),
            Mode::Files if has_query => "No matching files.".into(),
            Mode::Files => "No files found.".into(),
            Mode::Content if !self.target_online(engine) => {
                "Open a project to search its files.".into()
            }
            Mode::Content if has_query && !self.searching() && self.error.is_empty() => {
                "No results found.".into()
            }
            Mode::Content => "Type to search across your project.".into(),
            Mode::Browse if self.relative_without_project(engine) => {
                "Relative paths require an active project.".into()
            }
            Mode::Browse if !self.error.is_empty() => self.error.clone(),
            Mode::Browse if !self.browse_options.empty_text.is_empty() => {
                self.browse_options.empty_text.clone()
            }
            Mode::Browse if has_query && !self.searching() => {
                "Press Enter to create this folder and add it as a project.".into()
            }
            Mode::Browse => String::new(),
            Mode::Ask => self.ask_empty.clone(),
            Mode::Command if self.searching() => "Searching thread messages…".into(),
            Mode::Command if self.query.starts_with('>') => "No matching actions.".into(),
            Mode::Command => "No matching commands, projects, or threads.".into(),
        }
    }

    /// A line over the results: the environments a thread search did not
    /// reach, or the content search's count ("3 results in 2 files").
    pub fn status(&self, engine: &Engine) -> String {
        // A thread search only reaches the environments that are online:
        // the others are named.
        if self.mode == Mode::Command
            && self.views.is_empty()
            && !self.query.starts_with('>')
            && normalize(&self.query).chars().count() >= 2
        {
            let skipped: BTreeMap<String, String> = store::with(engine, |s| {
                s.environments()
                    .into_iter()
                    .filter(|e| !s.environment_online(e))
                    .map(|e| {
                        let label = text_of(&s.environment(&e), "label");
                        let label = if label.is_empty() { e.clone() } else { label };
                        (e, label)
                    })
                    .collect()
            });
            if skipped.is_empty() {
                return String::new();
            }
            let labels: Vec<String> = skipped.into_values().collect();
            return format!("Not searched (offline): {}", labels.join(", "));
        }
        if self.mode != Mode::Content || self.query.trim().is_empty() {
            return String::new();
        }
        if self.searching() {
            return "Searching…".into();
        }
        if !self.error.is_empty() {
            return self.error.clone();
        }
        if self.invalid_regex {
            return "Invalid regular expression".into();
        }
        let files: HashSet<&str> = self.entries.iter().map(|e| e.group.as_str()).collect();
        format!(
            "{}{} results in {} files",
            self.entries.len(),
            if self.truncated { "+" } else { "" },
            files.len()
        )
    }

    fn shown(&self, engine: &Engine) -> Props {
        let submit_label = self.submit_label(engine);
        Props {
            open: self.open,
            mode: self.mode.name(),
            submenu: self.submenu(),
            placeholder: self.placeholder(engine),
            query: self.query.clone(),
            highlighted: self.highlighted,
            count: self.count(),
            empty_text: self.empty_text(engine),
            status: self.status(engine),
            submit_shortcut: self.submit_shortcut(engine, &submit_label),
            submit_label,
            case_sensitive: self.case_sensitive,
            whole_word: self.whole_word,
            use_regex: self.use_regex,
        }
    }

    /// Writes to `PaletteModel` what changed since it was last written,
    /// `open` last: what opens the popup reads the rest.
    pub fn sync(&mut self, engine: &Engine) {
        let next = self.shown(engine);
        let was = std::mem::replace(&mut *self.props.borrow_mut(), next.clone());
        if was == next {
            return;
        }
        let Some(obj) = self.object else { return };
        let cx = Cx::new(engine, obj);
        let atom = |s: &str| Atom::from(s);
        if was.mode != next.mode {
            let _ = cx.set(PaletteObject::MODE, atom(next.mode));
        }
        if was.submenu != next.submenu {
            let _ = cx.set(PaletteObject::SUBMENU, atom(&next.submenu));
        }
        if was.placeholder != next.placeholder {
            let _ = cx.set(PaletteObject::PLACEHOLDER, atom(&next.placeholder));
        }
        if was.query != next.query {
            let _ = cx.set(PaletteObject::QUERY, atom(&next.query));
        }
        if was.case_sensitive != next.case_sensitive {
            let _ = cx.set(PaletteObject::CASE_SENSITIVE, next.case_sensitive);
        }
        if was.whole_word != next.whole_word {
            let _ = cx.set(PaletteObject::WHOLE_WORD, next.whole_word);
        }
        if was.use_regex != next.use_regex {
            let _ = cx.set(PaletteObject::USE_REGEX, next.use_regex);
        }
        if was.count != next.count {
            let _ = cx.set(PaletteObject::COUNT, next.count);
        }
        if was.empty_text != next.empty_text {
            let _ = cx.set(PaletteObject::EMPTY_TEXT, atom(&next.empty_text));
        }
        if was.status != next.status {
            let _ = cx.set(PaletteObject::STATUS, atom(&next.status));
        }
        if was.highlighted != next.highlighted {
            let _ = cx.set(PaletteObject::HIGHLIGHTED, next.highlighted);
        }
        if was.submit_label != next.submit_label {
            let _ = cx.set(PaletteObject::SUBMIT_LABEL, atom(&next.submit_label));
        }
        if was.submit_shortcut != next.submit_shortcut {
            let _ = cx.set(PaletteObject::SUBMIT_SHORTCUT, atom(&next.submit_shortcut));
        }
        if was.open != next.open {
            let _ = cx.set(PaletteObject::OPEN, next.open);
            // While it is open the thread's keys wait.
            Keymap::of(engine).set_palette_open(engine, next.open);
        }
    }
}

/// What a menu command's choices are read from.
fn menu(command: &str) -> Choices {
    let command = command.to_owned();
    Rc::new(move |engine| Commands::of(engine).choices(engine, &command))
}

fn with_haystacks(mut entries: Vec<Entry>) -> Vec<Entry> {
    for entry in &mut entries {
        entry.haystack = simplified(&entry.terms.join(" "));
    }
    entries
}

fn text_of(row: &store::Row, key: &str) -> String {
    row.get(key)
        .and_then(Json::as_str)
        .unwrap_or_default()
        .to_owned()
}

/// When the user last wrote in the thread, else when it last changed.
fn recency(thread: &sidebar_model::Thread) -> i64 {
    let at = match &thread.latest_user_message_at {
        Some(at) => Some(at.as_str()),
        None if !thread.updated_at.is_empty() => Some(thread.updated_at.as_str()),
        None => Some(thread.created_at.as_str()),
    };
    sidebar_model::parse_iso(at).unwrap_or(0)
}

/// An answer and its error, as desktop-qt reads one: what failed has none.
fn split(result: Result<Json, McError>) -> (Json, String) {
    match result {
        Ok(answer) => (answer, String::new()),
        Err(error) => (Json::Null, error.message),
    }
}

/// Where files and content are searched: the route thread's environment and
/// its worktree, else its project's folder.
fn target(engine: &Engine) -> Target {
    let Route::Thread(key) = navigation::shown(engine) else {
        return Target::default();
    };
    let environment_id = key.split(':').next().unwrap_or_default().to_owned();
    let root = store::with(engine, |s| {
        let row = s.thread_row(&key);
        let worktree = row.map(|r| text_of(r, "worktreePath")).unwrap_or_default();
        if !worktree.is_empty() {
            return worktree;
        }
        let project = row.map(|r| text_of(r, "projectId")).unwrap_or_default();
        s.project_row(&environment_id, &project)
            .map(|r| text_of(r, "workspaceRoot"))
            .unwrap_or_default()
    });
    if root.is_empty() {
        return Target::default();
    }
    Target {
        environment_id,
        root,
    }
}

/// `PaletteModel` in QML: the palette's state and the rows its list shows.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "PaletteModel", uncreatable)]
#[qml_singleton]
pub struct PaletteObject {
    #[qml(notify, readonly)]
    open: bool,
    /// command, files, content, browse or ask.
    #[qml(notify, readonly)]
    mode: Atom,
    /// The submenu shown, empty at the root.
    #[qml(notify, readonly)]
    submenu: Atom,
    #[qml(notify, readonly)]
    placeholder: Atom,
    #[qml(notify)]
    query: Atom,
    #[qml(notify, write = Self::keep_highlighted)]
    highlighted: i32,
    #[qml(notify, readonly)]
    count: i32,
    #[qml(notify, readonly)]
    empty_text: Atom,
    #[qml(notify, readonly)]
    status: Atom,
    /// In browse mode, what Enter does with the path typed ("Add", "Create &
    /// Add", "Clone"...) and the key that does it; empty when nothing can be
    /// added.
    #[qml(notify, readonly)]
    submit_label: Atom,
    #[qml(notify, readonly)]
    submit_shortcut: Atom,
    #[qml(notify)]
    case_sensitive: bool,
    #[qml(notify)]
    whole_word: bool,
    #[qml(notify)]
    use_regex: bool,
}

impl Default for PaletteObject {
    fn default() -> Self {
        PaletteObject {
            open: false,
            mode: Atom::from(Mode::Command.name()),
            submenu: Atom::from(""),
            placeholder: Atom::from(""),
            query: Atom::from(""),
            highlighted: 0,
            count: 0,
            empty_text: Atom::from(""),
            status: Atom::from(""),
            submit_label: Atom::from(""),
            submit_shortcut: Atom::from(""),
            case_sensitive: false,
            whole_word: false,
            use_regex: false,
        }
    }
}

impl PaletteObject {
    /// The setter of `highlighted`, as `setHighlighted` is in C++: a row
    /// past the rows shown (or below the first, but in browse mode, which
    /// leaves nothing highlighted until the user moves) is stored as the
    /// nearest row, so a view hears nothing when that is the row it has.
    fn keep_highlighted(&self, row: i32) -> Option<i32> {
        let lowest = if &*self.mode == Mode::Browse.name() {
            -1
        } else {
            0
        };
        Some(if self.count == 0 {
            lowest
        } else {
            row.clamp(lowest, self.count - 1)
        })
    }
}

#[qml_impl]
impl PaletteObject {
    #[qml(invokable)]
    fn show(cx: &Cx) {
        show(cx.engine);
    }

    #[qml(invokable)]
    fn toggle(cx: &Cx) {
        toggle(cx.engine);
    }

    #[qml(invokable)]
    fn toggle_mode(cx: &Cx, mode: Atom) {
        toggle_mode(cx.engine, &mode);
    }

    #[qml(invokable)]
    fn dismiss(cx: &Cx) {
        later(cx.engine, |c, engine| c.dismiss(engine));
    }

    #[qml(invokable)]
    fn back(cx: &Cx) {
        later(cx.engine, |c, engine| c.back(engine));
    }

    #[qml(invokable)]
    fn leave_submenu(cx: &Cx) -> bool {
        now(cx.engine, |c, engine| c.leave_submenu(engine))
    }

    #[qml(invokable, name = "move")]
    fn move_by(cx: &Cx, delta: i32) {
        later(cx.engine, move |c, _| c.move_by(delta));
    }

    #[qml(invokable)]
    fn run(cx: &Cx, row: i32) -> bool {
        now(cx.engine, |c, engine| c.run(engine, row))
    }

    #[qml(invokable)]
    fn run_highlighted(cx: &Cx) -> bool {
        now(cx.engine, |c, engine| c.run_highlighted(engine))
    }

    #[qml(invokable)]
    fn add_browsed_folder(cx: &Cx) -> bool {
        now(cx.engine, |c, engine| c.add_browsed_folder(engine))
    }

    #[qml(invokable)]
    fn set_settings_sections(cx: &Cx, sections: Json) {
        let sections = sections.as_array().cloned().unwrap_or_default();
        later(cx.engine, move |c, engine| {
            c.set_settings_sections(engine, sections);
        });
    }
}
