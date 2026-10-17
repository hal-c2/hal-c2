//! `terminals`, desktop-qt's TerminalController: the thread's terminals,
//! the drawer's (which thread's are shown, whether the drawer is open and
//! how tall, its tabs) and the right panel's terminal tabs, and the RPCs
//! behind them. The bricks read it as the `Terminals` singleton
//! ([`TerminalsObject`]). The thread (drafts too), its project root,
//! worktree and scripts are the workspace's [`workspace::place`]; the
//! terminals come from the MC (`terminals` shape). They are attached the
//! first time the drawer opens on that thread (or a panel tab does) and stay
//! attached while the thread is on screen, so hiding the drawer keeps their
//! output, and for the last few threads the user left
//! ([`MAX_PARKED_THREADS`]), so does coming back.
//!
//! Terminals split into groups: `terminal.split` and
//! `terminal.splitVertical {terminalId?}` add a terminal beside or under one
//! (the payload's, else the focused one, else the drawer's active one), at
//! most four to a group. A group made for the right panel
//! ([`Terminals::add_panel_group`]) is shown in a `terminal:<group>` tab and
//! never in the drawer; the drawer shows every other group, one tab each.
//! Ids are shared: at most six per thread.
//!
//! A build without the terminal's QML module ([`set_supported`]`(false)`)
//! has no terminals at all: [`supported`] is the one thing the bricks and
//! the other controllers ask before they offer, open or draw one.
//!
//! Each terminal is a [`Session`]: attached to the MC's session with a
//! `terminal` shape for as long as it lives. Its QML object
//! ([`TerminalSessionObject`]) is what a `Terminal` item feeds `write` and
//! `resize` and draws `output` from.

use std::cell::{Cell, RefCell};
use std::cmp::Ordering;
use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::rc::{Rc, Weak};
use std::sync::LazyLock;

use ljos::prelude::{Atom, Cx, Engine, ObjectId, QmlObject, Value, qml_impl, qml_singleton};
use ljos_engine::RowKey;
use regex::Regex;
use serde_json::{Map, json};

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::keybindings::Keymap;
use crate::controllers::menus::{Answer, Menus};
use crate::controllers::toasts::{DEFAULT_TIMEOUT_MS, Toasts};
use crate::controllers::workspace;
use crate::json::{self, Json};
use crate::mc::{Frame, Mc, SubId};
use crate::thread_view::rows::{ListRows, RowChange, RowSource, int};

pub const MAX_TERMINALS: usize = 6;
pub const MAX_PER_GROUP: usize = 4;
pub const MINIMUM_HEIGHT: i32 = 180;
/// Threads the user left whose terminals stay attached: coming back shows
/// what they printed meanwhile, with no new attach.
pub const MAX_PARKED_THREADS: usize = 10;
const DEFAULT_HEIGHT: i32 = 280;
/// How many threads' drawers the store remembers.
const STORED_THREADS: usize = 50;
/// TerminalWriteInput's limit, in UTF-16 units as the contract counts.
const MAX_WRITE: usize = 65536;
/// What the transcript keeps for a late Terminal, as the other clients cap
/// their buffers (docs/internals/terminal-runtime.md); the MC keeps the
/// full history. In UTF-16 units, as desktop-qt counts.
const MAX_TRANSCRIPT: usize = 512 * 1024;

type Hook = Rc<dyn Fn(&Engine)>;

/// What the app says of the terminals before any window, and who follows
/// them.
struct Env {
    supported: Cell<bool>,
    drawn: Cell<bool>,
    changed: RefCell<Vec<Hook>>,
}

impl Default for Env {
    fn default() -> Self {
        Env {
            supported: Cell::new(true),
            drawn: Cell::new(true),
            changed: RefCell::default(),
        }
    }
}

/// Whether this build can draw a terminal (the bricks' Ghostty module is
/// there). The desktop always can.
pub fn supported(engine: &Engine) -> bool {
    engine.extension::<Env>().supported.get()
}

/// The app says so once, before any window.
pub fn set_supported(engine: &Engine, supported: bool) {
    engine.extension::<Env>().supported.set(supported);
    if let Ok(obj) = engine.singleton::<TerminalsObject>() {
        let _ = Cx::new(engine, obj).set(TerminalsObject::SUPPORTED, supported);
    }
    refresh(engine);
}

/// Whether the window's layout has anywhere to draw a terminal. A layout
/// without a drawer or a panel (a phone's) says no, and the thread then has
/// no place for one, so no command opens a shell nobody can see.
pub fn set_drawn(engine: &Engine, drawn: bool) {
    if engine.extension::<Env>().drawn.replace(drawn) != drawn {
        refresh(engine);
    }
}

/// After what the `Terminals` singleton shows changed (the thread, whether
/// it has terminals, the drawer, the active terminal, the groups); once no
/// controller is running.
pub fn on_changed(engine: &Engine, f: impl Fn(&Engine) + 'static) {
    engine
        .extension::<Env>()
        .changed
        .borrow_mut()
        .push(Rc::new(f));
}

/// Where the drawer's height and, per thread, whether it is open and on
/// which terminal are kept across restarts; read at once.
pub fn set_store_path(engine: &Engine, path: Option<PathBuf>) {
    controller::with::<Terminals, _>(engine, |t, engine| t.set_store_path(engine, path));
}

fn refresh(engine: &Engine) {
    Bridge::of(engine).defer(engine, |engine| {
        controller::with::<Terminals, _>(engine, |t, engine| t.refresh(engine));
    });
}

fn toast(engine: &Engine, title: &str, description: &str) {
    controller::with::<Toasts, _>(engine, |t, engine| {
        t.show(
            engine,
            "error",
            title,
            description,
            None,
            DEFAULT_TIMEOUT_MS,
        )
    });
}

// --- Ids and labels ---------------------------------------------------------

static NUMBERED: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)^term(?:inal)?-([0-9]+)$").expect("a valid pattern"));

/// `term-N` (or `terminal-N`) as N; -1 for any other id.
fn terminal_number(terminal_id: &str) -> i32 {
    NUMBERED
        .captures(terminal_id)
        .map_or(-1, |c| c[1].parse().unwrap_or(0))
}

/// The MC's label, else "Terminal N".
fn terminal_label(terminal_id: &str, label: &str) -> String {
    let label = label.trim();
    if !label.is_empty() {
        return label.to_owned();
    }
    match terminal_number(terminal_id) {
        n if n >= 0 => format!("Terminal {n}"),
        _ => terminal_id.to_owned(),
    }
}

/// Numbered terminals in order, anything else after them.
fn terminal_order(left: &str, right: &str) -> Ordering {
    let (a, b) = (terminal_number(left), terminal_number(right));
    if (a < 0) != (b < 0) {
        return if a >= 0 {
            Ordering::Less
        } else {
            Ordering::Greater
        };
    }
    a.cmp(&b).then_with(|| left.cmp(right))
}

fn utf16_len(text: &str) -> usize {
    text.chars().map(char::len_utf16).sum()
}

/// The longest start of `text` of at most `limit` UTF-16 units, never
/// splitting a character.
fn utf16_prefix(text: &str, limit: usize) -> usize {
    let mut units = 0;
    for (at, c) in text.char_indices() {
        units += c.len_utf16();
        if units > limit {
            return at;
        }
    }
    text.len()
}

/// QDir::cleanPath: no `.`, `..` resolved, no doubled or trailing `/`.
fn clean_path(path: &str) -> String {
    let absolute = path.starts_with('/');
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => match parts.last() {
                Some(&last) if last != ".." => {
                    parts.pop();
                }
                _ if absolute => {}
                _ => parts.push(".."),
            },
            _ => parts.push(part),
        }
    }
    let joined = parts.join("/");
    match (absolute, joined.is_empty()) {
        (true, _) => format!("/{joined}"),
        (false, true) => ".".to_owned(),
        (false, false) => joined,
    }
}

/// `path:line:column` as the path and the `:line:column` it ends with (at
/// most two numbers).
fn split_position(text: &str) -> (&str, &str) {
    let mut end = text.len();
    for _ in 0..2 {
        let Some(colon) = text[..end].rfind(':') else {
            break;
        };
        let digits = &text[colon + 1..end];
        if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
            break;
        }
        end = colon;
    }
    text.split_at(end)
}

static HOME: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(/Users/[^/]+|/home/[^/]+)").expect("a valid pattern"));

// --- Where a thread's terminals run ----------------------------------------

/// Where a thread's terminals run: the environment that owns the thread
/// (the MC routes its shapes and RPCs there), and the launch context every
/// terminal of the thread starts with.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct TerminalPlace {
    pub environment_id: String,
    pub thread_id: String,
    pub cwd: String,
    /// Empty without a worktree.
    pub worktree_path: String,
    pub env: Map<String, Json>,
    pub scripts: Vec<Json>,
    /// A provider's setup terminal: the MC runs it with that instance's env
    /// and home.
    pub provider_instance_id: String,
}

impl TerminalPlace {
    /// `terminal.open`'s input (and the `terminal` shape's).
    pub fn launch_input(&self, terminal_id: &str) -> Map<String, Json> {
        let mut input = Map::new();
        input.insert("threadId".into(), self.thread_id.clone().into());
        input.insert("terminalId".into(), terminal_id.into());
        input.insert("cwd".into(), self.cwd.clone().into());
        input.insert("env".into(), Json::Object(self.env.clone()));
        if !self.worktree_path.is_empty() {
            input.insert("worktreePath".into(), self.worktree_path.clone().into());
        }
        if !self.provider_instance_id.is_empty() {
            input.insert(
                "providerInstanceId".into(),
                self.provider_instance_id.clone().into(),
            );
        }
        input
    }
}

// --- One terminal -----------------------------------------------------------

/// What a session tells whoever opened it.
#[derive(Clone, Debug, PartialEq)]
pub enum SessionEvent {
    /// The first snapshot arrived: the shell is running.
    Attached,
    /// The MC refused to open the terminal.
    Failed(String),
    /// The MC closed the terminal (from this or another client).
    Closed,
    /// Its shell ended on its own.
    Exited,
    /// The Terminal settled on a size (columns, rows).
    Resized(i32, i32),
}

type OnEvent = Box<dyn Fn(&Engine, &SessionEvent)>;

#[derive(Default)]
struct SessionState {
    subscription: Option<SubId>,
    attached: bool,
    transcript: VecDeque<String>,
    transcript_size: usize,
    pending_write: String,
    writing: bool,
    wanted: Option<(i32, i32)>,
    sent: Option<(i32, i32)>,
    resizing: bool,
}

struct SessionInner {
    mc: Rc<dyn Mc>,
    environment_id: String,
    thread_id: String,
    terminal_id: String,
    object: Cell<Option<ObjectId>>,
    ended: Cell<bool>,
    state: RefCell<SessionState>,
    on_event: OnEvent,
}

impl Drop for SessionInner {
    fn drop(&mut self) {
        if let Some(id) = self.state.get_mut().subscription.take() {
            self.mc.unsubscribe(id);
        }
    }
}

/// One terminal on the MC, attached with a `terminal` shape until it is
/// [`end`](Session::end)ed. The QML Terminal feeds `write` and `resize`
/// and draws `output`; `replaced` hands it a whole new screen (attach,
/// reattach after a reconnect, clear, restart). The transcript lets a
/// Terminal created after the attach (a reloaded rice) catch up.
#[derive(Clone)]
pub struct Session(Rc<SessionInner>);

impl std::fmt::Debug for Session {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("Session").field(&self.0.terminal_id).finish()
    }
}

impl PartialEq for Session {
    fn eq(&self, other: &Self) -> bool {
        Rc::ptr_eq(&self.0, &other.0)
    }
}

impl Session {
    /// Attaches to `terminal_id` of `place`, opening it at `size` (columns,
    /// rows) when the MC starts it. `on_event` hears what happens to it; it
    /// runs from the MC's frames and the Terminal's calls, never inside
    /// this one.
    pub fn open(
        engine: &Engine,
        mc: Rc<dyn Mc>,
        place: &TerminalPlace,
        terminal_id: &str,
        size: Option<(i32, i32)>,
        on_event: impl Fn(&Engine, &SessionEvent) + 'static,
    ) -> Session {
        let mut input = place.launch_input(terminal_id);
        if let Some((columns, rows)) = size {
            input.insert("cols".into(), columns.into());
            input.insert("rows".into(), rows.into());
        }
        let session = Session(Rc::new(SessionInner {
            mc: mc.clone(),
            environment_id: place.environment_id.clone(),
            thread_id: place.thread_id.clone(),
            terminal_id: terminal_id.to_owned(),
            object: Cell::new(None),
            ended: Cell::new(false),
            state: RefCell::new(SessionState {
                wanted: size,
                sent: size,
                ..SessionState::default()
            }),
            on_event: Box::new(on_event),
        }));
        let object = TerminalSessionObject {
            terminal_id: Atom::new(terminal_id),
            session: SessionRef(Rc::downgrade(&session.0)),
        };
        session
            .0
            .object
            .set(engine.create_native(object, None).ok());
        let weak = Rc::downgrade(&session.0);
        let subscription = mc.subscribe(
            json!({ "type": "terminal", "environment": place.environment_id, "input": input }),
            Box::new(move |engine, frame| {
                if let Some(inner) = weak.upgrade() {
                    Session(inner).on_frame(engine, frame);
                }
            }),
            None,
        );
        session.0.state.borrow_mut().subscription = Some(subscription);
        session
    }

    /// The QML object the Terminal reads (`session` of a tab).
    pub fn object(&self) -> Option<ObjectId> {
        self.0.object.get()
    }

    pub fn terminal_id(&self) -> &str {
        &self.0.terminal_id
    }

    /// The size last sent to the MC (or opened at).
    pub fn size(&self) -> Option<(i32, i32)> {
        self.0.state.borrow().sent
    }

    pub fn attached(&self) -> bool {
        self.0.state.borrow().attached
    }

    /// Whether the session still follows the MC's terminal.
    pub fn subscribed(&self) -> bool {
        self.0.state.borrow().subscription.is_some()
    }

    pub fn transcript(&self) -> String {
        self.0
            .state
            .borrow()
            .transcript
            .iter()
            .map(String::as_str)
            .collect()
    }

    /// Keystrokes, pastes and replies from the Terminal: sent one request
    /// at a time, since the MC runs each RPC on its own and would reorder
    /// them.
    pub fn write(&self, engine: &Engine, data: &str) {
        if self.0.ended.get() {
            return;
        }
        self.0.state.borrow_mut().pending_write.push_str(data);
        self.flush_writes(engine);
    }

    /// Only the latest size matters; one resize is in flight at a time.
    pub fn resize(&self, engine: &Engine, columns: i32, rows: i32) {
        if columns <= 0 || rows <= 0 || self.0.ended.get() {
            return;
        }
        self.0.state.borrow_mut().wanted = Some((columns, rows));
        (self.0.on_event)(engine, &SessionEvent::Resized(columns, rows));
        self.flush_resize(engine);
    }

    /// Stops following the terminal (the MC keeps it running) and lets its
    /// QML object go, once its Terminal item is done with it.
    pub fn end(&self, engine: &Engine) {
        if self.0.ended.replace(true) {
            return;
        }
        self.unsubscribe();
        if let Some(obj) = self.0.object.take() {
            engine.destroy(obj);
        }
    }

    fn unsubscribe(&self) {
        let id = self.0.state.borrow_mut().subscription.take();
        if let Some(id) = id {
            self.0.mc.unsubscribe(id);
        }
    }

    fn on_frame(&self, engine: &Engine, frame: &Frame) {
        if self.0.ended.get() {
            return;
        }
        let text = |value: Option<&Json>| value.and_then(Json::as_str).unwrap_or("").to_owned();
        match frame.get("t").and_then(Json::as_str) {
            Some("error") => {
                // The MC refused the attach and forgot the shape.
                self.unsubscribe();
                let reason = text(frame.get("reason"));
                self.note(engine, &reason);
                (self.0.on_event)(engine, &SessionEvent::Failed(reason));
                return;
            }
            Some("terminal") => {}
            _ => return,
        }
        let event = frame.get("event").cloned().unwrap_or(Json::Null);
        match event["type"].as_str().unwrap_or("") {
            "snapshot" | "restarted" => {
                // Every (re)subscription starts with a snapshot: the screen
                // starts over.
                self.replace(engine, &text(event["snapshot"].get("history")));
                let first = !std::mem::replace(&mut self.0.state.borrow_mut().attached, true);
                if first {
                    self.flush_writes(engine);
                    (self.0.on_event)(engine, &SessionEvent::Attached);
                }
                // The attach's size can be older than what the Terminal
                // settled on since.
                let resend = {
                    let mut state = self.0.state.borrow_mut();
                    let resend = state.wanted.is_some();
                    if resend {
                        state.sent = None;
                    }
                    resend
                };
                if resend {
                    self.flush_resize(engine);
                }
            }
            "output" => self.append(engine, &text(event.get("data"))),
            "cleared" => self.replace(engine, ""),
            "exited" => {
                self.note(engine, "process exited");
                (self.0.on_event)(engine, &SessionEvent::Exited);
            }
            "error" => self.note(engine, &text(event.get("message"))),
            "closed" => {
                // Attaching again (on a reconnect) would open the terminal
                // anew.
                self.unsubscribe();
                (self.0.on_event)(engine, &SessionEvent::Closed);
            }
            _ => {}
        }
    }

    fn append(&self, engine: &Engine, data: &str) {
        if data.is_empty() {
            return;
        }
        {
            let mut state = self.0.state.borrow_mut();
            state.transcript.push_back(data.to_owned());
            state.transcript_size += utf16_len(data);
            while state.transcript_size > MAX_TRANSCRIPT && state.transcript.len() > 1 {
                if let Some(oldest) = state.transcript.pop_front() {
                    state.transcript_size -= utf16_len(&oldest);
                }
            }
        }
        if let Some(obj) = self.object() {
            let _ = TerminalSessionObject::emit_output(&Cx::new(engine, obj), Atom::new(data));
        }
    }

    fn replace(&self, engine: &Engine, history: &str) {
        {
            let mut state = self.0.state.borrow_mut();
            state.transcript.clear();
            state.transcript_size = 0;
            if !history.is_empty() {
                state.transcript.push_back(history.to_owned());
                state.transcript_size = utf16_len(history);
            }
        }
        if let Some(obj) = self.object() {
            let _ = TerminalSessionObject::emit_replaced(&Cx::new(engine, obj), Atom::new(history));
        }
    }

    /// Said in the terminal itself, as the terminal client does.
    fn note(&self, engine: &Engine, text: &str) {
        self.append(engine, &format!("\r\n[{text}]\r\n"));
    }

    fn flush_writes(&self, _engine: &Engine) {
        let chunk = {
            let mut state = self.0.state.borrow_mut();
            if state.writing || !state.attached || state.pending_write.is_empty() {
                return;
            }
            let at = utf16_prefix(&state.pending_write, MAX_WRITE);
            let rest = state.pending_write.split_off(at);
            state.writing = true;
            std::mem::replace(&mut state.pending_write, rest)
        };
        let weak = Rc::downgrade(&self.0);
        self.0.mc.call(
            &self.0.environment_id,
            "terminal.write",
            json!({
                "threadId": self.0.thread_id,
                "terminalId": self.0.terminal_id,
                "data": chunk,
            }),
            Box::new(move |engine, result| {
                let Some(inner) = weak.upgrade() else { return };
                {
                    let mut state = inner.state.borrow_mut();
                    state.writing = false;
                    if result.is_err() {
                        // Typing into an ended shell, or no MC: what was
                        // typed is gone.
                        state.pending_write.clear();
                        return;
                    }
                }
                if !inner.ended.get() {
                    Session(inner).flush_writes(engine);
                }
            }),
        );
    }

    fn flush_resize(&self, _engine: &Engine) {
        let (columns, rows) = {
            let mut state = self.0.state.borrow_mut();
            let Some(wanted) = state.wanted else { return };
            if state.resizing || !state.attached || state.sent == Some(wanted) {
                return;
            }
            state.sent = Some(wanted);
            state.resizing = true;
            wanted
        };
        let weak = Rc::downgrade(&self.0);
        self.0.mc.call(
            &self.0.environment_id,
            "terminal.resize",
            json!({
                "threadId": self.0.thread_id,
                "terminalId": self.0.terminal_id,
                "cols": columns,
                "rows": rows,
            }),
            Box::new(move |engine, _| {
                let Some(inner) = weak.upgrade() else { return };
                inner.state.borrow_mut().resizing = false;
                if !inner.ended.get() {
                    Session(inner).flush_resize(engine);
                }
            }),
        );
    }
}

/// What a session's QML object reaches it through; nothing once it ended.
#[derive(Default)]
struct SessionRef(Weak<SessionInner>);

impl std::fmt::Debug for SessionRef {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("SessionRef")
    }
}

/// A [`Session`] in QML: `write`, `resize`, `transcript()`, `output` and
/// `replaced`, as desktop-qt's TerminalSession.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "TerminalSession", uncreatable)]
pub struct TerminalSessionObject {
    #[qml(constant, readonly)]
    terminal_id: Atom,
    #[qml(skip)]
    session: SessionRef,
}

fn session_of(cx: &Cx) -> Option<Session> {
    cx.engine
        .with::<TerminalSessionObject, _>(cx.this, |o| o.session.0.upgrade())
        .ok()
        .flatten()
        .map(Session)
}

#[qml_impl]
impl TerminalSessionObject {
    #[qml(signal)]
    fn output(data: Atom);
    #[qml(signal)]
    fn replaced(history: Atom);

    #[qml(invokable)]
    fn write(cx: &Cx, data: Value) {
        let data = cx.engine.to_js_string(&data);
        if let Some(session) = session_of(cx) {
            session.write(cx.engine, &data);
        }
    }

    #[qml(invokable)]
    fn resize(cx: &Cx, columns: i32, rows: i32) {
        if let Some(session) = session_of(cx) {
            session.resize(cx.engine, columns, rows);
        }
    }

    #[qml(invokable)]
    fn transcript(cx: &Cx) -> String {
        session_of(cx).map(|s| s.transcript()).unwrap_or_default()
    }
}

// --- The tabs ---------------------------------------------------------------

/// A terminal the drawer or a panel tab shows, and where it sits: its split
/// group, its slot in the group's row or column, and whether it is the one
/// its group shows focused.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Tab {
    pub terminal_id: String,
    pub label: String,
    pub busy: bool,
    pub session: Option<Session>,
    /// The split group; a terminal never split is a group of its own.
    pub group: String,
    /// In a right panel tab rather than the drawer.
    pub panel: bool,
    /// Its place among the group's `span` terminals, left to right or top
    /// to bottom.
    pub slot: i32,
    pub span: i32,
    /// Stacked rather than side by side.
    pub vertical: bool,
    /// The one its group has active (the drawer's active terminal, or a
    /// panel tab's).
    pub current: bool,
}

impl Tab {
    fn same_layout(&self, other: &Tab) -> bool {
        self.label == other.label
            && self.busy == other.busy
            && self.group == other.group
            && self.panel == other.panel
            && self.slot == other.slot
            && self.span == other.span
            && self.vertical == other.vertical
            && self.current == other.current
    }
}

const TAB_ROLES: &[&str] = &[
    "terminalId",
    "label",
    "busy",
    "session",
    "group",
    "panel",
    "slot",
    "span",
    "vertical",
    "current",
];

#[derive(Default)]
struct TabRows {
    rows: Vec<(RowKey, Tab)>,
    next_key: RowKey,
    changes: Vec<RowChange>,
}

impl RowSource for TabRows {
    fn roles(&self) -> &'static [&'static str] {
        TAB_ROLES
    }

    fn row_count(&self) -> usize {
        self.rows.len()
    }

    fn row_key(&self, row: usize) -> RowKey {
        self.rows.get(row).map_or(row as RowKey, |(key, _)| *key)
    }

    fn data(&self, row: usize, role: &str) -> Value {
        let Some((_, tab)) = self.rows.get(row) else {
            return Value::Undefined;
        };
        match role {
            "terminalId" => Value::from(tab.terminal_id.as_str()),
            "label" => Value::from(tab.label.as_str()),
            "busy" => Value::Bool(tab.busy),
            "session" => tab
                .session
                .as_ref()
                .and_then(Session::object)
                .map_or(Value::Null, Value::Object),
            "group" => Value::from(tab.group.as_str()),
            "panel" => Value::Bool(tab.panel),
            "slot" => Value::from(tab.slot),
            "span" => Value::from(tab.span),
            "vertical" => Value::Bool(tab.vertical),
            "current" => Value::Bool(tab.current),
            _ => Value::Undefined,
        }
    }

    fn take_changes(&mut self) -> Vec<RowChange> {
        std::mem::take(&mut self.changes)
    }
}

/// `Terminals.tabs`: one row per session, the drawer's and the right
/// panel's. Rows are inserted and removed one by one so the Terminal items
/// made for the others keep their screens.
#[derive(Debug, Default, QmlObject)]
#[qml(module = "HalC2.Shell", name = "TerminalTabs", uncreatable)]
pub struct TerminalTabsObject {
    #[qml(notify, readonly)]
    count: i32,
}

struct Tabs {
    rows: Rc<ListRows<TabRows>>,
    object: Option<ObjectId>,
}

impl Tabs {
    fn new(engine: &Engine) -> Tabs {
        let rows = ListRows::new(TabRows::default());
        let object = engine
            .create_native(TerminalTabsObject::default(), None)
            .ok();
        if let Some(obj) = object {
            let _ = rows.attach(engine, obj);
        }
        Tabs { rows, object }
    }

    fn rows(&self) -> Vec<Tab> {
        self.rows
            .read(|r| r.rows.iter().map(|(_, t)| t.clone()).collect())
    }

    fn len(&self) -> usize {
        self.rows.read(|r| r.rows.len())
    }

    fn id_at(&self, index: usize) -> String {
        self.rows.read(|r| {
            r.rows
                .get(index)
                .map(|(_, t)| t.terminal_id.clone())
                .unwrap_or_default()
        })
    }

    fn index_of(&self, terminal_id: &str) -> Option<usize> {
        self.rows.read(|r| {
            r.rows
                .iter()
                .position(|(_, t)| t.terminal_id == terminal_id)
        })
    }

    fn session(&self, terminal_id: &str) -> Option<Session> {
        self.rows.read(|r| {
            r.rows
                .iter()
                .find(|(_, t)| t.terminal_id == terminal_id)
                .and_then(|(_, t)| t.session.clone())
        })
    }

    fn counted(&self, engine: &Engine) {
        if let Some(obj) = self.object {
            let count = int(self.rows.shown_count());
            let _ = Cx::new(engine, obj).set(TerminalTabsObject::COUNT, count);
        }
    }

    fn insert(&self, engine: &Engine, index: usize, tab: Tab) {
        self.rows.update(engine, |r| {
            let index = index.min(r.rows.len());
            let key = r.next_key;
            r.next_key += 1;
            r.rows.insert(index, (key, tab));
            r.changes.push(RowChange::Inserted {
                first: index,
                keys: vec![key],
            });
        });
        self.counted(engine);
    }

    /// Ends the row's session.
    fn remove(&self, engine: &Engine, index: usize) {
        let gone = self.rows.update(engine, |r| {
            if index >= r.rows.len() {
                return None;
            }
            let (_, tab) = r.rows.remove(index);
            r.changes.push(RowChange::Removed {
                first: index,
                count: 1,
            });
            tab.session
        });
        if let Some(session) = gone {
            session.end(engine);
        }
        self.counted(engine);
    }

    /// Everything but the session.
    fn update(&self, engine: &Engine, index: usize, next: Tab) {
        self.rows.update(engine, |r| {
            let Some((_, tab)) = r.rows.get_mut(index) else {
                return;
            };
            if tab.same_layout(&next) {
                return;
            }
            let session = tab.session.take();
            *tab = Tab { session, ..next };
            r.changes.push(RowChange::Changed {
                first: index,
                count: 1,
                roles: &[],
            });
        });
    }

    /// Empties the model and hands its sessions over, alive, by terminal id.
    fn take(&self, engine: &Engine) -> HashMap<String, Session> {
        if self.len() == 0 {
            return HashMap::new();
        }
        let sessions = self.rows.update(engine, |r| {
            let sessions = r
                .rows
                .drain(..)
                .filter_map(|(_, t)| t.session.map(|s| (t.terminal_id, s)))
                .collect();
            r.changes.push(RowChange::Reset(Vec::new()));
            sessions
        });
        self.counted(engine);
        sessions
    }

    fn clear(&self, engine: &Engine) {
        for session in self.take(engine).into_values() {
            session.end(engine);
        }
    }
}

// --- The controller --------------------------------------------------------

/// `Terminals` in QML.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "Terminals", uncreatable)]
#[qml_singleton]
pub struct TerminalsObject {
    #[qml(notify, readonly)]
    supported: bool,
    #[qml(notify, readonly)]
    available: bool,
    #[qml(notify, readonly)]
    open: bool,
    #[qml(notify, readonly)]
    height: i32,
    #[qml(notify, readonly)]
    active_terminal_id: Atom,
    /// The drawer's shown group (its active terminal's).
    #[qml(notify, readonly)]
    active_group: Atom,
    /// {group: terminal count} for every split or panel group.
    #[qml(notify, readonly)]
    group_sizes: Value,
    /// TerminalTabs.
    #[qml(notify, readonly)]
    tabs: Value,
}

impl Default for TerminalsObject {
    fn default() -> Self {
        TerminalsObject {
            supported: true,
            available: false,
            open: false,
            height: DEFAULT_HEIGHT,
            active_terminal_id: Atom::new(""),
            active_group: Atom::new(""),
            group_sizes: Value::Undefined,
            tabs: Value::Null,
        }
    }
}

#[qml_impl]
impl TerminalsObject {
    /// The terminal's drawer or panel tab should give it the keyboard.
    #[qml(signal)]
    fn focus_requested(terminal_id: Atom);

    /// A terminal took the keyboard: it becomes its group's active one, and
    /// the one split and keybindings act on.
    #[qml(invokable)]
    fn focus_terminal(cx: &Cx, terminal_id: Atom) {
        let terminal_id = terminal_id.to_string();
        // The tab rows a change makes can take the keyboard while it is
        // being made.
        Bridge::of(cx.engine).defer(cx.engine, move |engine| {
            controller::with::<Terminals, _>(engine, |t, engine| {
                t.focus_terminal(engine, &terminal_id)
            });
        });
    }
}

#[derive(Clone, Debug, Default)]
struct Summary {
    label: String,
    busy: bool,
}

/// A split group, or a right panel tab's.
#[derive(Clone, Debug, Default, PartialEq)]
struct Group {
    id: String,
    terminals: Vec<String>,
    vertical: bool,
    panel: bool,
    active: String,
}

#[derive(Clone, Debug, Default)]
struct ThreadUi {
    open: bool,
    /// The drawer's active terminal.
    active: String,
    /// Split and panel groups; any other terminal is a group of its own.
    groups: Vec<Group>,
    /// Opened here and not yet listed by the MC.
    local: HashSet<String>,
    /// Closed here; ignored until the MC confirms.
    closing: HashSet<String>,
    /// Read from the store and not yet checked against the MC's terminals:
    /// the drawer waits for the list rather than open on a terminal that is
    /// gone.
    restored: bool,
}

fn group_of<'a>(ui: &'a ThreadUi, terminal_id: &str) -> Option<&'a Group> {
    ui.groups
        .iter()
        .find(|g| g.terminals.iter().any(|t| t == terminal_id))
}

fn group_of_mut<'a>(ui: &'a mut ThreadUi, terminal_id: &str) -> Option<&'a mut Group> {
    ui.groups
        .iter_mut()
        .find(|g| g.terminals.iter().any(|t| t == terminal_id))
}

/// The drawer's terminals (none of the panel's) among `ids`.
fn drawer_ids(ui: &ThreadUi, ids: &[String]) -> Vec<String> {
    ids.iter()
        .filter(|id| group_of(ui, id).is_none_or(|g| !g.panel))
        .cloned()
        .collect()
}

/// The attached sessions of a thread the user left, and where they ran.
struct Parked {
    cwd: String,
    sessions: HashMap<String, Session>,
}

/// What `changed` notifies (the right panel reads the thread key too).
#[derive(Clone, Debug, Default, PartialEq)]
struct Facts {
    thread_key: String,
    available: bool,
    open: bool,
    height: i32,
    active: String,
    active_group: String,
    group_sizes: BTreeMap<String, usize>,
}

pub struct Terminals {
    bridge: Bridge,
    mc: Rc<dyn Mc>,
    me: Me<Terminals>,
    active: bool,
    /// The thread whose terminals these are ("<environment>:<thread id>").
    thread_key: String,
    place: Option<TerminalPlace>,
    /// Whether the thread on screen has its terminals attached.
    attached: bool,
    height: i32,
    /// The size the last terminal settled on, for the next one to open at.
    size: Option<(i32, i32)>,
    ui: HashMap<String, ThreadUi>,
    /// Terminals the MC lists, per thread key.
    known: HashMap<String, BTreeMap<String, Summary>>,
    /// The `terminals` subscription per environment.
    watched: HashMap<String, SubId>,
    tabs: Tabs,
    /// The terminal that last had the keyboard.
    focused: String,
    group_count: u32,
    parked: HashMap<String, Parked>,
    /// Oldest first.
    parked_order: Vec<String>,
    store_path: Option<PathBuf>,
    saved: Vec<u8>,
    /// Threads in the order their drawers were last used, oldest first.
    recent: Vec<String>,
    told: Facts,
}

impl Drop for Terminals {
    fn drop(&mut self) {
        for (_, id) in self.watched.drain() {
            self.mc.unsubscribe(id);
        }
    }
}

impl Controller for Terminals {
    fn new(init: Init<'_, Self>) -> Self {
        let engine = init.engine;
        let tabs = Tabs::new(engine);
        if let Ok(obj) = engine.singleton::<TerminalsObject>() {
            let cx = Cx::new(engine, obj);
            let _ = cx.set(TerminalsObject::SUPPORTED, supported(engine));
            let _ = cx.set(
                TerminalsObject::TABS,
                tabs.object.map_or(Value::Null, Value::Object),
            );
            let _ = cx.set(
                TerminalsObject::GROUP_SIZES,
                json::to_value(engine, &json!({})),
            );
        }
        let mut terminals = Terminals {
            bridge: init.bridge,
            mc: init.mc,
            me: init.me,
            active: false,
            thread_key: String::new(),
            place: None,
            attached: false,
            height: DEFAULT_HEIGHT,
            size: None,
            ui: HashMap::new(),
            known: HashMap::new(),
            watched: HashMap::new(),
            tabs,
            focused: String::new(),
            group_count: 0,
            parked: HashMap::new(),
            parked_order: Vec::new(),
            store_path: None,
            saved: Vec::new(),
            recent: Vec::new(),
            told: Facts::default(),
        };
        terminals.told = terminals.facts();
        terminals
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let later = |me: &Me<Terminals>| {
            let me = me.clone();
            move |engine: &Engine| {
                let me = me.clone();
                Bridge::of(engine).defer(engine, move |engine| me.run(engine, Terminals::refresh));
            }
        };
        crate::store::on_changed(engine, later(&self.me));
        workspace::on_place_changed(engine, later(&self.me));
        self.refresh(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !self.active {
            return false;
        }
        let arg = |key: &str| payload[key].as_str().unwrap_or_default().to_owned();
        match action {
            "terminal.toggle" => {
                if self.place.is_some() && self.set_open(engine, !self.is_open()) && self.is_open()
                {
                    let active = self.active_terminal_id();
                    self.focus_requested(engine, &active);
                }
            }
            "terminal.resize" => {
                let asked = payload["height"].as_f64().map_or(0, |h| h.round() as i32);
                let height = asked.max(MINIMUM_HEIGHT);
                if height != self.height {
                    self.height = height;
                    self.notify(engine);
                }
            }
            "terminal.new" => {
                if self.place.is_none() {
                    return true;
                }
                if self.terminal_ids().len() >= MAX_TERMINALS {
                    toast(
                        engine,
                        &format!("At most {MAX_TERMINALS} terminals per thread."),
                        "",
                    );
                    return true;
                }
                let id = self.next_terminal_id();
                self.open_terminal(engine, &id);
            }
            "terminal.split" | "terminal.splitVertical" => {
                self.split(
                    engine,
                    &arg("terminalId"),
                    action == "terminal.splitVertical",
                );
            }
            "terminal.select" => {
                let id = arg("terminalId");
                if self.place.is_some() && self.terminal_ids().contains(&id) {
                    self.open_terminal(engine, &id);
                }
            }
            "terminal.followLink" => {
                self.follow_link(engine, &arg("kind"), &arg("text"), &arg("cwd"));
            }
            "terminal.close" => {
                if self.place.is_none() {
                    return true;
                }
                // A keybinding's is the focused terminal's, the drawer's or a
                // panel tab's.
                let ids = self.terminal_ids();
                let fallback = if ids.contains(&self.focused) {
                    self.focused.clone()
                } else {
                    self.active_terminal_id()
                };
                let terminal_id = match payload.get("terminalId") {
                    Some(id) => id.as_str().unwrap_or_default().to_owned(),
                    None => fallback,
                };
                if !ids.contains(&terminal_id) {
                    return true;
                }
                let thread_key = self.thread_key.clone();
                let me = self.me.clone();
                let id = terminal_id.clone();
                self.confirm_close(
                    engine,
                    &[terminal_id],
                    Rc::new(move |engine| {
                        let (thread_key, id) = (thread_key.clone(), id.clone());
                        me.run(engine, move |t, engine| {
                            if thread_key == t.thread_key && t.terminal_ids().contains(&id) {
                                t.close_terminal(engine, &id);
                            }
                        });
                    }),
                );
            }
            _ => return false,
        }
        true
    }
}

impl Terminals {
    // --- What the bricks and the other controllers read ------------------

    /// Whether the thread on screen has a place for terminals.
    pub fn available(&self) -> bool {
        self.place.is_some()
    }

    pub fn is_open(&self) -> bool {
        self.place.is_some()
            && self
                .ui
                .get(&self.thread_key)
                .is_some_and(|ui| ui.open && !ui.restored)
    }

    pub fn height(&self) -> i32 {
        self.height
    }

    /// The thread whose terminals these are ("<environment>:<thread id>").
    pub fn thread_key(&self) -> &str {
        &self.thread_key
    }

    pub fn active_terminal_id(&self) -> String {
        if self.place.is_none() {
            return String::new();
        }
        self.ui
            .get(&self.thread_key)
            .map(|ui| ui.active.clone())
            .unwrap_or_default()
    }

    pub fn active_group(&self) -> String {
        if self.place.is_none() {
            return String::new();
        }
        let Some(ui) = self.ui.get(&self.thread_key) else {
            return String::new();
        };
        if ui.active.is_empty() {
            return String::new();
        }
        group_of(ui, &ui.active).map_or_else(|| ui.active.clone(), |g| g.id.clone())
    }

    /// {group: terminal count} for every split or panel group.
    pub fn group_sizes(&self) -> BTreeMap<String, usize> {
        if self.place.is_none() {
            return BTreeMap::new();
        }
        self.ui
            .get(&self.thread_key)
            .map(|ui| {
                ui.groups
                    .iter()
                    .map(|g| (g.id.clone(), g.terminals.len()))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// The tab rows as the bricks see them.
    pub fn tabs(&self) -> Vec<Tab> {
        self.tabs.rows()
    }

    /// The session of a terminal the tabs show.
    pub fn session(&self, terminal_id: &str) -> Option<Session> {
        self.tabs.session(terminal_id)
    }

    /// The right panel's groups of a thread, in the order they were added.
    pub fn panel_groups(&self, thread_key: &str) -> Vec<String> {
        self.ui
            .get(thread_key)
            .map(|ui| {
                ui.groups
                    .iter()
                    .filter(|g| g.panel)
                    .map(|g| g.id.clone())
                    .collect()
            })
            .unwrap_or_default()
    }

    /// The terminals of a split or panel group.
    pub fn group_terminals(&self, group: &str) -> Vec<String> {
        self.ui
            .get(&self.thread_key)
            .and_then(|ui| ui.groups.iter().find(|g| g.id == group))
            .map(|g| g.terminals.clone())
            .unwrap_or_default()
    }

    /// The thread's terminals: the MC's and the ones opened here, less the
    /// ones closing; numbered ones first.
    pub fn terminal_ids(&self) -> Vec<String> {
        let ui = self.ui.get(&self.thread_key);
        let mut ids: HashSet<&str> = ui
            .map(|ui| ui.local.iter().map(String::as_str).collect())
            .unwrap_or_default();
        if let Some(known) = self.known.get(&self.thread_key) {
            ids.extend(known.keys().map(String::as_str));
        }
        if let Some(ui) = ui {
            for id in &ui.closing {
                ids.remove(id.as_str());
            }
        }
        let mut sorted: Vec<String> = ids.into_iter().map(str::to_owned).collect();
        sorted.sort_by(|a, b| terminal_order(a, b));
        sorted
    }

    // --- What the other controllers do -----------------------------------

    /// A terminal took the keyboard: it becomes its group's active one, and
    /// the one split and keybindings act on.
    pub fn focus_terminal(&mut self, engine: &Engine, terminal_id: &str) {
        if self.place.is_none() || !self.terminal_ids().iter().any(|id| id == terminal_id) {
            return;
        }
        self.focused = terminal_id.to_owned();
        let ui = self.ui_mut();
        let active = match ui
            .groups
            .iter_mut()
            .find(|g| g.terminals.iter().any(|t| t == terminal_id))
        {
            Some(group) if group.panel => &mut group.active,
            _ => &mut ui.active,
        };
        if active == terminal_id {
            return;
        }
        *active = terminal_id.to_owned();
        self.sync_tabs(engine);
        self.notify(engine);
    }

    /// Opens a terminal in a new group of the right panel's; returns the
    /// group, or nothing when the thread has no place for terminals or no
    /// room.
    pub fn add_panel_group(&mut self, engine: &Engine) -> Option<String> {
        if !self.active || self.place.is_none() {
            return None;
        }
        if self.terminal_ids().len() >= MAX_TERMINALS {
            toast(
                engine,
                &format!("At most {MAX_TERMINALS} terminals per thread."),
                "",
            );
            return None;
        }
        self.ui_mut().restored = false;
        let id = self.next_terminal_id();
        self.group_count += 1;
        let group = format!("group-{}", self.group_count);
        let ui = self.ui_mut();
        ui.local.insert(id.clone());
        ui.groups.push(Group {
            id: group.clone(),
            terminals: vec![id.clone()],
            vertical: false,
            panel: true,
            active: id.clone(),
        });
        self.sync_tabs(engine);
        self.notify(engine);
        self.focus_requested(engine, &id);
        Some(group)
    }

    /// Closes every terminal of the group (deleting their history).
    pub fn close_group(&mut self, engine: &Engine, group: &str) {
        if self.place.is_none() {
            return;
        }
        for id in self.group_terminals(group) {
            self.close_terminal(engine, &id);
        }
    }

    /// Asks before the user's own close of `ids`: one question naming every
    /// terminal. `accepted` runs on yes; with nothing to close it runs at
    /// once (once no controller is running).
    pub fn confirm_close(&mut self, engine: &Engine, ids: &[String], accepted: Answer) {
        let at_once = |engine: &Engine, accepted: Answer| {
            Bridge::of(engine).defer(engine, move |engine| accepted(engine));
        };
        if ids.is_empty() {
            at_once(engine, accepted);
            return;
        }
        let known = self.known.get(&self.thread_key);
        let labels: Vec<String> = ids
            .iter()
            .map(|id| {
                let label = known
                    .and_then(|k| k.get(id))
                    .map_or("", |s| s.label.as_str());
                format!("\"{}\"", terminal_label(id, label))
            })
            .collect();
        let (title, description, confirm) = if ids.len() == 1 {
            (
                format!("Close terminal {}?", labels[0]),
                "This stops the running process and clears its history.".to_owned(),
                "Close terminal",
            )
        } else {
            (
                format!("Close {} terminals?", ids.len()),
                format!(
                    "This stops their running processes and clears their histories: {}.",
                    labels.join(", ")
                ),
                "Close terminals",
            )
        };
        let asked = controller::with::<Menus, _>(engine, |menus, engine| {
            menus.confirm(
                engine,
                &title,
                &description,
                confirm,
                true,
                Some(accepted.clone()),
                None,
            );
        });
        if asked.is_none() {
            at_once(engine, accepted);
        }
    }

    /// Runs a project script in the active terminal, or a new one when that
    /// one is busy. False without a place or such a script.
    pub fn run_script(&mut self, engine: &Engine, script_id: &str) -> bool {
        if !supported(engine) {
            toast(
                engine,
                "This build of HAL-C2 has no terminal",
                "Project actions run in one. Run it from HAL-C2 on a computer.",
            );
            return false;
        }
        // A layout with no place for a terminal (the phone's): the action's
        // key is not taken without a word.
        if !engine.extension::<Env>().drawn.get() {
            toast(
                engine,
                "No terminal on a screen this small",
                "Project actions run in one. Run it from a wider window or another device.",
            );
            return false;
        }
        let Some(place) = self.place.clone().filter(|_| self.active) else {
            return false;
        };
        let Some(script) = place
            .scripts
            .iter()
            .rev()
            .find(|s| s["id"].as_str() == Some(script_id))
            .cloned()
        else {
            return false;
        };
        let name = script["name"].as_str().unwrap_or_default().to_owned();
        let ids = self.terminal_ids();
        let active = self.active_terminal_id();
        let mut terminal_id = if !active.is_empty() {
            active
        } else if let Some(first) = ids.first() {
            first.clone()
        } else {
            self.next_terminal_id()
        };
        let busy = self
            .known
            .get(&self.thread_key)
            .and_then(|k| k.get(&terminal_id))
            .is_some_and(|s| s.busy);
        if busy {
            if ids.len() >= MAX_TERMINALS {
                toast(
                    engine,
                    &format!("At most {MAX_TERMINALS} terminals per thread."),
                    "",
                );
                return true;
            }
            terminal_id = self.next_terminal_id();
        }
        self.open_terminal(engine, &terminal_id);
        // terminal.open restarts a shell that has ended, so the script
        // always runs.
        let mut input = place.launch_input(&terminal_id);
        if let Some((columns, rows)) = self.tabs.session(&terminal_id).and_then(|s| s.size()) {
            input.insert("cols".into(), columns.into());
            input.insert("rows".into(), rows.into());
        }
        let command = format!("{}\r", script["command"].as_str().unwrap_or_default());
        let thread_key = self.thread_key.clone();
        let mc = self.mc.clone();
        let environment_id = place.environment_id.clone();
        self.mc.call(
            &environment_id,
            "terminal.open",
            Json::Object(input),
            Box::new(move |engine, result| {
                let failed = format!("Failed to run script \"{name}\".");
                if let Err(error) = result {
                    toast(engine, &failed, &error.message);
                    return;
                }
                let shown = controller::with::<Terminals, _>(engine, |t, _| {
                    t.tabs
                        .session(&terminal_id)
                        .filter(|_| t.thread_key == thread_key)
                })
                .flatten();
                if let Some(session) = shown {
                    session.write(engine, &command);
                    return;
                }
                // The user moved on; the script still runs.
                mc.call(
                    &place.environment_id,
                    "terminal.write",
                    json!({
                        "threadId": place.thread_id,
                        "terminalId": terminal_id,
                        "data": command,
                    }),
                    Box::new(move |engine, result| {
                        if let Err(error) = result {
                            toast(engine, &failed, &error.message);
                        }
                    }),
                );
            }),
        );
        true
    }

    // --- Where the terminals are -----------------------------------------

    fn set_store_path(&mut self, engine: &Engine, path: Option<PathBuf>) {
        self.store_path = path;
        let Some(bytes) = self
            .store_path
            .as_deref()
            .and_then(|p| std::fs::read(p).ok())
        else {
            return;
        };
        let stored: Json = serde_json::from_slice(&bytes).unwrap_or(Json::Null);
        self.saved = bytes;
        let height = stored["height"]
            .as_f64()
            .filter(|h| h.fract() == 0.0 && *h >= f64::from(i32::MIN) && *h <= f64::from(i32::MAX))
            .map_or(self.height, |h| h as i32);
        self.height = height.max(MINIMUM_HEIGHT);
        for thread in stored["threads"].as_array().into_iter().flatten() {
            let thread_key = thread["threadKey"].as_str().unwrap_or_default();
            if thread_key.is_empty() {
                continue;
            }
            let ui = self.ui.entry(thread_key.to_owned()).or_default();
            ui.open = thread["open"].as_bool().unwrap_or(false);
            ui.active = thread["active"].as_str().unwrap_or_default().to_owned();
            ui.restored = true;
            self.recent.retain(|k| k != thread_key);
            self.recent.push(thread_key.to_owned());
        }
        self.notify(engine);
    }

    fn save(&mut self) {
        let Some(path) = self.store_path.clone() else {
            return;
        };
        if !self.thread_key.is_empty() && self.ui.contains_key(&self.thread_key) {
            self.recent.retain(|k| *k != self.thread_key);
            self.recent.push(self.thread_key.clone());
        }
        let mut threads = VecDeque::new();
        for thread_key in self.recent.iter().rev() {
            if threads.len() >= STORED_THREADS {
                break;
            }
            let ui = self.ui.get(thread_key).cloned().unwrap_or_default();
            if !ui.open && ui.active.is_empty() {
                continue;
            }
            threads.push_front(json!({
                "threadKey": thread_key,
                "open": ui.open,
                "active": ui.active,
            }));
        }
        let stored = json!({ "height": self.height, "threads": Vec::from(threads) });
        let Ok(bytes) = serde_json::to_vec(&stored) else {
            return;
        };
        if bytes == self.saved {
            return;
        }
        if write_atomically(&path, &bytes).is_ok() {
            self.saved = bytes;
        }
    }

    fn facts(&self) -> Facts {
        Facts {
            thread_key: self.thread_key.clone(),
            available: self.available(),
            open: self.is_open(),
            height: self.height,
            active: self.active_terminal_id(),
            active_group: self.active_group(),
            group_sizes: self.group_sizes(),
        }
    }

    /// Saves, and tells the bricks, the keymap and the other controllers
    /// when what it notifies differs from what it last did.
    fn notify(&mut self, engine: &Engine) {
        self.save();
        let now = self.facts();
        if now == self.told {
            return;
        }
        let was_open = self.told.open;
        self.told = now.clone();
        if let Ok(obj) = engine.singleton::<TerminalsObject>() {
            let cx = Cx::new(engine, obj);
            let _ = cx.set(TerminalsObject::AVAILABLE, now.available);
            let _ = cx.set(TerminalsObject::OPEN, now.open);
            let _ = cx.set(TerminalsObject::HEIGHT, now.height);
            let _ = cx.set(TerminalsObject::ACTIVE_TERMINAL_ID, Atom::new(&now.active));
            let _ = cx.set(TerminalsObject::ACTIVE_GROUP, Atom::new(&now.active_group));
            let sizes = json!(now.group_sizes);
            let _ = cx.set(TerminalsObject::GROUP_SIZES, json::to_value(engine, &sizes));
        }
        let bridge = self.bridge;
        if was_open != now.open {
            let open = now.open;
            bridge.defer(engine, move |engine| {
                Keymap::of(engine).set_terminal_open(engine, open);
            });
        }
        let hooks = engine.extension::<Env>().changed.borrow().clone();
        for hook in hooks {
            bridge.defer(engine, move |engine| hook(engine));
        }
    }

    fn focus_requested(&self, engine: &Engine, terminal_id: &str) {
        if let Ok(obj) = engine.singleton::<TerminalsObject>() {
            let _ = TerminalsObject::emit_focus_requested(
                &Cx::new(engine, obj),
                Atom::new(terminal_id),
            );
        }
    }

    fn ui_mut(&mut self) -> &mut ThreadUi {
        self.ui.entry(self.thread_key.clone()).or_default()
    }

    /// Where the route's thread (a draft too) runs its terminals: its
    /// project root, worktree and scripts.
    fn place_of_workspace(&self, engine: &Engine) -> Option<TerminalPlace> {
        // No terminal in this build, or nowhere in the layout to draw one:
        // no thread has a place for it.
        if !supported(engine) || !engine.extension::<Env>().drawn.get() {
            return None;
        }
        let at = workspace::place(engine)?;
        if at.root.is_empty() || at.thread_id.is_empty() {
            return None;
        }
        // The environment a project script runs with; T3CODE_ is what older
        // scripts read.
        let mut env = Map::new();
        env.insert("HAL_C2_PROJECT_ROOT".into(), at.root.clone().into());
        env.insert("T3CODE_PROJECT_ROOT".into(), at.root.clone().into());
        if !at.worktree_path.is_empty() {
            env.insert(
                "HAL_C2_WORKTREE_PATH".into(),
                at.worktree_path.clone().into(),
            );
            env.insert(
                "T3CODE_WORKTREE_PATH".into(),
                at.worktree_path.clone().into(),
            );
        }
        Some(TerminalPlace {
            cwd: at.cwd().to_owned(),
            environment_id: at.environment_id,
            thread_id: at.thread_id,
            worktree_path: at.worktree_path,
            env,
            scripts: at.scripts,
            provider_instance_id: String::new(),
        })
    }

    fn refresh(&mut self, engine: &Engine) {
        if !self.active {
            return;
        }
        let place = self.place_of_workspace(engine);
        let thread_key = place
            .as_ref()
            .map(|p| format!("{}:{}", p.environment_id, p.thread_id))
            .unwrap_or_default();
        if let Some(place) = &place {
            self.watch(&place.environment_id);
        }
        // Another thread, or the same one launching elsewhere: start over.
        let moved = thread_key != self.thread_key
            || match (&place, &self.place) {
                (Some(next), Some(now)) => next.cwd != now.cwd,
                _ => true,
            };
        if moved {
            // Leaving a thread keeps its terminals attached; a thread that
            // now runs somewhere else starts over.
            match &self.place {
                Some(now) if thread_key != self.thread_key && self.attached => {
                    let (left, cwd) = (self.thread_key.clone(), now.cwd.clone());
                    self.park(engine, &left, &cwd);
                }
                _ => self.tabs.clear(engine),
            }
            self.attached = false;
            self.focused.clear();
            if let (Some(place), Some(parked)) = (&place, self.parked.get(&thread_key)) {
                if parked.cwd == place.cwd {
                    self.attached = true;
                } else {
                    self.drop_parked(engine, &thread_key);
                }
            }
        }
        self.thread_key = thread_key;
        self.place = place;
        self.sync_tabs(engine);
        self.notify(engine);
    }

    /// Brings the tab rows (and their sessions) in line with the thread's
    /// terminals.
    fn sync_tabs(&mut self, engine: &Engine) {
        let Some(place) = self.place.clone() else {
            return;
        };
        let ids = self.terminal_ids();
        let attached = self.attached;
        let ui = self.ui_mut();
        if ui.restored {
            return;
        }
        // A group loses the terminals that ended, and goes with the last
        // one.
        ui.groups.retain_mut(|group| {
            group.terminals.retain(|id| ids.contains(id));
            if !group.terminals.contains(&group.active) {
                group.active = group.terminals.last().cloned().unwrap_or_default();
            }
            !group.terminals.is_empty()
        });
        let drawer = drawer_ids(ui, &ids);
        // The MC closed the last one (here or elsewhere, while the user was
        // away too): the drawer hides.
        if ui.open && drawer.is_empty() {
            ui.open = false;
        }
        if !drawer.contains(&ui.active) {
            ui.active = drawer.last().cloned().unwrap_or_default();
        }
        let panel = drawer.len() < ids.len();
        if !ui.open && !attached && !panel {
            return;
        }
        let ui = ui.clone();
        self.attached = true;
        let thread_key = self.thread_key.clone();
        let known = self.known.get(&thread_key).cloned().unwrap_or_default();
        for i in (0..self.tabs.len()).rev() {
            if !ids.contains(&self.tabs.id_at(i)) {
                self.tabs.remove(engine, i);
            }
        }
        for (i, id) in ids.iter().enumerate() {
            let summary = known.get(id).cloned().unwrap_or_default();
            let mut tab = Tab {
                terminal_id: id.clone(),
                label: terminal_label(id, &summary.label),
                busy: summary.busy,
                session: None,
                group: id.clone(),
                panel: false,
                slot: 0,
                span: 1,
                vertical: false,
                current: ui.active == *id,
            };
            if let Some(group) = group_of(&ui, id) {
                tab.group = group.id.clone();
                tab.panel = group.panel;
                tab.slot = int(group.terminals.iter().position(|t| t == id).unwrap_or(0));
                tab.span = int(group.terminals.len());
                tab.vertical = group.vertical;
                tab.current = if group.panel {
                    group.active == *id
                } else {
                    ui.active == *id
                };
            }
            if let Some(index) = self.tabs.index_of(id) {
                self.tabs.update(engine, index, tab);
                continue;
            }
            // Still attached from the user's last visit.
            let parked = self
                .parked
                .get_mut(&thread_key)
                .and_then(|p| p.sessions.remove(id));
            tab.session = Some(match parked {
                Some(session) => session,
                None => self.open_session(engine, &place, id),
            });
            self.tabs.insert(engine, i, tab);
        }
        // What the visit left that the thread no longer has.
        self.drop_parked(engine, &thread_key);
    }

    fn open_session(&self, engine: &Engine, place: &TerminalPlace, terminal_id: &str) -> Session {
        let me = self.me.clone();
        let thread_key = self.thread_key.clone();
        let id = terminal_id.to_owned();
        Session::open(
            engine,
            self.mc.clone(),
            place,
            terminal_id,
            self.size,
            move |engine, event| {
                let (me, thread_key, id, event) =
                    (me.clone(), thread_key.clone(), id.clone(), event.clone());
                Bridge::of(engine).defer(engine, move |engine| {
                    me.run(engine, |t, engine| {
                        t.on_session(engine, &thread_key, &id, event)
                    });
                });
            },
        )
    }

    fn on_session(&mut self, engine: &Engine, thread_key: &str, id: &str, event: SessionEvent) {
        match event {
            SessionEvent::Resized(columns, rows) => self.size = Some((columns, rows)),
            SessionEvent::Closed => {
                self.ui
                    .entry(thread_key.to_owned())
                    .or_default()
                    .local
                    .remove(id);
                self.known
                    .entry(thread_key.to_owned())
                    .or_default()
                    .remove(id);
                let mut emptied = false;
                if let Some(parked) = self.parked.get_mut(thread_key) {
                    if let Some(gone) = parked.sessions.remove(id) {
                        gone.end(engine);
                    }
                    emptied = parked.sessions.is_empty();
                }
                if emptied {
                    self.drop_parked(engine, thread_key);
                }
                if thread_key == self.thread_key {
                    self.sync_tabs(engine);
                    self.notify(engine);
                }
            }
            // A shell that ended on its own takes its terminal with it,
            // unasked.
            SessionEvent::Exited => {
                if thread_key == self.thread_key && self.terminal_ids().iter().any(|t| t == id) {
                    self.close_terminal(engine, id);
                }
            }
            SessionEvent::Attached | SessionEvent::Failed(_) => {}
        }
    }

    fn park(&mut self, engine: &Engine, thread_key: &str, cwd: &str) {
        self.drop_parked(engine, thread_key);
        let sessions = self.tabs.take(engine);
        if sessions.is_empty() {
            return;
        }
        self.parked.insert(
            thread_key.to_owned(),
            Parked {
                cwd: cwd.to_owned(),
                sessions,
            },
        );
        self.parked_order.push(thread_key.to_owned());
        while self.parked_order.len() > MAX_PARKED_THREADS {
            let oldest = self.parked_order[0].clone();
            self.drop_parked(engine, &oldest);
        }
    }

    fn drop_parked(&mut self, engine: &Engine, thread_key: &str) {
        self.parked_order.retain(|k| k != thread_key);
        if let Some(parked) = self.parked.remove(thread_key) {
            for session in parked.sessions.into_values() {
                session.end(engine);
            }
        }
    }

    /// Follows an environment's terminals list once a thread there is shown.
    fn watch(&mut self, environment_id: &str) {
        if self.watched.contains_key(environment_id) {
            return;
        }
        let me = self.me.clone();
        let environment = environment_id.to_owned();
        let id = self.mc.subscribe(
            json!({ "type": "terminals", "environment": environment_id }),
            Box::new(move |engine, frame| {
                if frame.get("t").and_then(Json::as_str) != Some("terminals") {
                    return;
                }
                let event = frame.get("event").cloned().unwrap_or(Json::Null);
                let environment = environment.clone();
                me.run(engine, |t, engine| {
                    t.on_terminals(engine, &environment, &event)
                });
            }),
            None,
        );
        self.watched.insert(environment_id.to_owned(), id);
    }

    fn on_terminals(&mut self, engine: &Engine, environment_id: &str, event: &Json) {
        let key_of =
            |thread_id: &Json| format!("{environment_id}:{}", thread_id.as_str().unwrap_or(""));
        let put = |t: &mut Terminals, terminal: &Json| {
            let key = key_of(&terminal["threadId"]);
            let id = terminal["terminalId"]
                .as_str()
                .unwrap_or_default()
                .to_owned();
            t.known.entry(key.clone()).or_default().insert(
                id.clone(),
                Summary {
                    label: terminal["label"].as_str().unwrap_or_default().to_owned(),
                    busy: terminal["hasRunningSubprocess"].as_bool().unwrap_or(false),
                },
            );
            t.ui.entry(key).or_default().local.remove(&id);
        };
        match event["type"].as_str().unwrap_or("") {
            "snapshot" => {
                let prefix = format!("{environment_id}:");
                self.known.retain(|key, _| !key.starts_with(&prefix));
                for terminal in event["terminals"].as_array().into_iter().flatten() {
                    put(self, terminal);
                }
                // What the store remembered holds as far as the MC still
                // runs it.
                for (key, ui) in &mut self.ui {
                    if !ui.restored || !key.starts_with(&prefix) {
                        continue;
                    }
                    ui.restored = false;
                    if self.known.get(key).is_none_or(BTreeMap::is_empty) {
                        ui.open = false;
                    }
                }
            }
            "upsert" => put(self, &event["terminal"]),
            "remove" => {
                let key = key_of(&event["threadId"]);
                let id = event["terminalId"].as_str().unwrap_or_default();
                self.known.entry(key.clone()).or_default().remove(id);
                self.ui.entry(key).or_default().local.remove(id);
            }
            _ => return,
        }
        self.sync_tabs(engine);
        self.notify(engine);
    }

    /// Returns whether the drawer's open state changed.
    fn set_open(&mut self, engine: &Engine, open: bool) -> bool {
        let ui = self.ui_mut();
        if std::mem::replace(&mut ui.restored, false) {
            ui.open = false;
        }
        if ui.open == open {
            return false;
        }
        ui.open = open;
        // A drawer with no terminal yet gets its first one.
        if open {
            let ids = self.terminal_ids();
            let ui = self.ui_mut();
            if drawer_ids(ui, &ids).is_empty() {
                let id = self.next_terminal_id();
                self.ui_mut().local.insert(id);
            }
        }
        self.sync_tabs(engine);
        self.notify(engine);
        true
    }

    /// Shows the terminal (opening it here if it is new) and gives it the
    /// keyboard. A terminal of a panel tab becomes the tab's active one
    /// instead.
    fn open_terminal(&mut self, engine: &Engine, terminal_id: &str) {
        let listed = self.terminal_ids().iter().any(|id| id == terminal_id);
        let ui = self.ui_mut();
        ui.restored = false;
        if !listed {
            ui.local.insert(terminal_id.to_owned());
        }
        match group_of_mut(ui, terminal_id) {
            Some(group) if group.panel => group.active = terminal_id.to_owned(),
            _ => {
                ui.active = terminal_id.to_owned();
                ui.open = true;
            }
        }
        self.sync_tabs(engine);
        self.notify(engine);
        self.focus_requested(engine, terminal_id);
    }

    /// A terminal beside (or under) `terminal_id` in its group: the group
    /// takes the new direction.
    fn split(&mut self, engine: &Engine, terminal_id: &str, vertical: bool) {
        if self.place.is_none() {
            return;
        }
        self.ui_mut().restored = false;
        let ids = self.terminal_ids();
        let mut target = if ids.iter().any(|id| id == terminal_id) {
            terminal_id.to_owned()
        } else if ids.contains(&self.focused) {
            self.focused.clone()
        } else {
            self.ui_mut().active.clone()
        };
        if target.is_empty() || !ids.contains(&target) {
            // A hidden drawer with no terminal yet gets its first one, then
            // the split.
            if !ids.is_empty() {
                return;
            }
            target = self.next_terminal_id();
            let ui = self.ui_mut();
            ui.local.insert(target.clone());
            ui.active = target.clone();
        }
        let size = group_of(self.ui_mut(), &target).map(|g| g.terminals.len());
        if size.is_some_and(|n| n >= MAX_PER_GROUP) {
            toast(
                engine,
                &format!("At most {MAX_PER_GROUP} terminals per group."),
                "",
            );
            return;
        }
        if ids.len() >= MAX_TERMINALS {
            toast(
                engine,
                &format!("At most {MAX_TERMINALS} terminals per thread."),
                "",
            );
            return;
        }
        let id = self.next_terminal_id();
        let new_group = size.is_none().then(|| {
            self.group_count += 1;
            format!("group-{}", self.group_count)
        });
        let ui = self.ui_mut();
        if let Some(group) = new_group {
            ui.groups.push(Group {
                id: group,
                terminals: vec![target.clone()],
                vertical,
                panel: false,
                active: target.clone(),
            });
        }
        ui.local.insert(id.clone());
        let mut panel = false;
        if let Some(group) = group_of_mut(ui, &target) {
            let at = group
                .terminals
                .iter()
                .position(|t| *t == target)
                .map_or(group.terminals.len(), |at| at + 1);
            group.terminals.insert(at, id.clone());
            group.vertical = vertical;
            group.active = id.clone();
            panel = group.panel;
        }
        if !panel {
            ui.active = id.clone();
            ui.open = true;
        }
        self.sync_tabs(engine);
        self.notify(engine);
        self.focus_requested(engine, &id);
    }

    fn close_terminal(&mut self, engine: &Engine, terminal_id: &str) {
        let Some(place) = self.place.clone() else {
            return;
        };
        let thread_key = self.thread_key.clone();
        let ui = self.ui_mut();
        ui.local.remove(terminal_id);
        ui.closing.insert(terminal_id.to_owned());
        // Closing the active one activates the last one left in its group,
        // else the drawer's last one.
        let mut next = String::new();
        let mut panel = false;
        if let Some(group) = group_of_mut(ui, terminal_id) {
            group.terminals.retain(|t| t != terminal_id);
            if group.active == terminal_id {
                group.active = group.terminals.last().cloned().unwrap_or_default();
            }
            next = group.active.clone();
            panel = group.panel;
            // sync_tabs drops it once empty.
            if !panel && ui.active == terminal_id {
                ui.active = next.clone();
            }
        } else if ui.active == terminal_id {
            ui.active.clear();
        }
        let ids = self.terminal_ids();
        let ui = self.ui_mut();
        if drawer_ids(ui, &ids).is_empty() {
            ui.open = false;
        }
        let me = self.me.clone();
        let mc = self.mc.clone();
        let id = terminal_id.to_owned();
        let environment_id = place.environment_id.clone();
        self.mc.call(
            &environment_id,
            "terminal.close",
            json!({
                "threadId": place.thread_id,
                "terminalId": terminal_id,
                "deleteHistory": true,
            }),
            Box::new(move |engine, result| {
                if result.is_err() {
                    // The MC no longer has the session to close: ask the
                    // shell itself to leave.
                    mc.call(
                        &place.environment_id,
                        "terminal.write",
                        json!({
                            "threadId": place.thread_id,
                            "terminalId": id,
                            "data": "exit\n",
                        }),
                        Box::new(|_, _| {}),
                    );
                }
                me.run(engine, |t, engine| {
                    t.ui.entry(thread_key.clone())
                        .or_default()
                        .closing
                        .remove(&id);
                    t.known.entry(thread_key.clone()).or_default().remove(&id);
                    if thread_key == t.thread_key {
                        t.sync_tabs(engine);
                        t.notify(engine);
                    }
                });
            }),
        );
        self.sync_tabs(engine);
        self.notify(engine);
        if panel && !next.is_empty() {
            self.focus_requested(engine, &next);
        } else if !panel && self.ui_mut().open {
            let active = self.active_terminal_id();
            self.focus_requested(engine, &active);
        }
    }

    /// A link the user followed in a terminal: a web address goes to the
    /// browser (the desktop draws no pages itself), a file path to the
    /// editor, resolved against the folder the shell reported (OSC 7) or the
    /// one the terminal started in.
    fn follow_link(&mut self, engine: &Engine, kind: &str, text: &str, reported_cwd: &str) {
        let Some(place) = &self.place else {
            return;
        };
        if text.is_empty() {
            return;
        }
        if kind == "url" {
            if url::Url::parse(text).is_ok_and(|u| matches!(u.scheme(), "http" | "https")) {
                self.bridge.open_external(engine, text);
            }
            return;
        }
        let (path, position) = split_position(text);
        let mut cwd = if reported_cwd.starts_with("file://") {
            // OSC 7 names the host too: only the path counts.
            url::Url::parse(reported_cwd)
                .map(|u| percent_decoded(u.path()))
                .unwrap_or_default()
        } else {
            reported_cwd.to_owned()
        };
        if cwd.is_empty() {
            cwd = place.cwd.clone();
        }
        let mut path = path.to_owned();
        if let Some(rest) = path.strip_prefix("~/") {
            // The home the folder sits in.
            if let Some(home) = HOME.find(&cwd) {
                path = format!("{}/{rest}", home.as_str());
            }
        } else if !path.starts_with('/') {
            path = clean_path(&format!("{cwd}/{path}"));
        }
        if !workspace::open_in_editor(engine, "", &format!("{path}{position}"), false) {
            toast(
                engine,
                "Unable to open path",
                &format!("This environment has no editor to open {path} in."),
            );
        }
    }

    /// The lowest free `term-N`; ids still closing stay taken until the MC
    /// lets go of them.
    fn next_terminal_id(&self) -> String {
        let mut used: HashSet<i32> = self
            .terminal_ids()
            .iter()
            .map(|id| terminal_number(id))
            .collect();
        if let Some(ui) = self.ui.get(&self.thread_key) {
            used.extend(ui.closing.iter().map(|id| terminal_number(id)));
        }
        let mut next = 1;
        while used.contains(&next) {
            next += 1;
        }
        format!("term-{next}")
    }
}

/// A URL's path as QUrl::path() gives it: `%XX` decoded.
fn percent_decoded(path: &str) -> String {
    let bytes = path.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut at = 0;
    while at < bytes.len() {
        let hex = bytes
            .get(at + 1..at + 3)
            .and_then(|h| std::str::from_utf8(h).ok())
            .and_then(|h| u8::from_str_radix(h, 16).ok());
        match (bytes[at], hex) {
            (b'%', Some(byte)) => {
                out.push(byte);
                at += 3;
            }
            (byte, _) => {
                out.push(byte);
                at += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Writes `bytes` to `path` whole or not at all, as QSaveFile does.
fn write_atomically(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let mut partial = path.as_os_str().to_owned();
    partial.push(".partial");
    std::fs::write(&partial, bytes)?;
    std::fs::rename(&partial, path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numbered_terminals_come_first_in_number_order() {
        let mut ids = vec!["shell", "term-10", "Terminal-2", "term-1", "alpha"];
        ids.sort_by(|a, b| terminal_order(a, b));
        assert_eq!(ids, ["term-1", "Terminal-2", "term-10", "alpha", "shell"]);
    }

    #[test]
    fn a_terminal_is_labelled_by_the_mc_else_by_its_number() {
        assert_eq!(terminal_label("term-3", "  build "), "build");
        assert_eq!(terminal_label("term-3", ""), "Terminal 3");
        assert_eq!(terminal_label("setup", " "), "setup");
    }

    #[test]
    fn a_link_keeps_at_most_two_positions() {
        assert_eq!(split_position("src/a.rs:12:4"), ("src/a.rs", ":12:4"));
        assert_eq!(split_position("a:1:2:3"), ("a:1", ":2:3"));
        assert_eq!(split_position("a.rs:"), ("a.rs:", ""));
        assert_eq!(split_position("a.rs:x"), ("a.rs:x", ""));
    }

    #[test]
    fn paths_are_cleaned_as_qdir_does() {
        assert_eq!(clean_path("/w/p/./src/../lib//a.rs"), "/w/p/lib/a.rs");
        assert_eq!(clean_path("/../a"), "/a");
        assert_eq!(clean_path("a/../../b/"), "../b");
        assert_eq!(clean_path("/"), "/");
    }

    #[test]
    fn a_reported_folder_is_its_decoded_path() {
        assert_eq!(percent_decoded("/home/a/my%20dir"), "/home/a/my dir");
        assert_eq!(percent_decoded("/a%2"), "/a%2");
    }

    #[test]
    fn writes_split_on_utf16_units_without_splitting_a_character() {
        let text = format!("{}😀", "a".repeat(MAX_WRITE - 1));
        assert_eq!(utf16_prefix(&text, MAX_WRITE), MAX_WRITE - 1);
        assert_eq!(utf16_prefix("abc", MAX_WRITE), 3);
    }
}
