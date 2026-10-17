//! desktop-qt's ThreadPreviews: the Previews tab, a thread's browser tabs
//! as the MC keeps them (`preview.list`), each opened in the user's browser
//! rather than embedded. While shown it follows the MC's `preview` events
//! (the MC serving the thread's environment).
//!
//! `close(tabId)` is `preview.close`: the row goes at once and stays gone
//! while the close is in flight; a close that fails brings it back where it
//! was.
//!
//! `newTab()` is `preview.open` with no address: an empty tab the user
//! fills from `suggestions`: the web servers listening on the MC's machine
//! (its `localServers` shape, followed only while the list shows), the
//! project's configured preview addresses and the pages this device opened
//! last. `navigate(tabId, url)` is `preview.navigate`, and opens the page in
//! the browser.
//!
//! [`Previews`] is the core: it takes events, frames and replies and says
//! what to ask of the MC as [`Effect`]s. [`ThreadPreviews`] is the object
//! QML binds; it runs those effects on the shell's MC.

use std::cell::RefCell;
use std::collections::HashSet;
use std::hash::{Hash, Hasher};
use std::rc::Rc;

use ljos::prelude::QmlValue;
use ljos::prelude::{Atom, Cx, Engine, ObjectId, QmlObject, Value, qml_impl};
use ljos::prelude::{EngineError, RowKey};
use serde_json::json;

use super::rows::{ListRows, RowChange, RowSource, int};
use crate::json::Json;
use crate::mc::{Mc, McError, SubId};

pub const ROLES: &[&str] = &["tabId", "url", "title", "status", "problem"];

/// The pages this device opened last that a new tab offers.
pub const MAX_RECENTS: usize = 10;

/// What a reply is for.
#[derive(Clone, Debug, PartialEq)]
pub enum Then {
    List {
        generation: u64,
    },
    Open {
        generation: u64,
    },
    Navigate {
        generation: u64,
        url: String,
    },
    /// The row the tab was at and the tab as it was, to bring it back.
    Close {
        row: usize,
        snapshot: Json,
        tab: String,
    },
}

/// What the previews ask of their owner, in order.
#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    /// Follow this MC's `localServers` and `preview` shapes.
    Follow(String),
    Unfollow,
    /// An RPC where the thread's environment is served; its answer goes to
    /// [`Previews::answer`] with `then`.
    Call {
        environment: String,
        method: &'static str,
        payload: Json,
        then: Then,
    },
    /// An error toast.
    Notify {
        title: &'static str,
        description: String,
    },
    /// A page for the user's browser.
    Open(String),
    /// The pages this device opened last, newest first, to keep.
    Remember(Vec<String>),
}

/// What changed besides the rows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PreviewNote {
    Count,
    /// status or message.
    Status,
    Suggestions,
}

fn text<'a>(object: &'a Json, key: &str) -> &'a str {
    object.get(key).and_then(Json::as_str).unwrap_or("")
}

fn nav_of(snapshot: &Json) -> &Json {
    static NONE: Json = Json::Null;
    snapshot.get("navStatus").unwrap_or(&NONE)
}

fn tab_of(snapshot: &Json) -> &str {
    text(snapshot, "tabId")
}

/// QJsonValue::toInteger(-1).
fn revision_of(event: &Json) -> i64 {
    event.get("revision").and_then(Json::as_i64).unwrap_or(-1)
}

/// What a row of `snapshot` shows as `role`.
pub fn shown(snapshot: &Json, role: &str) -> String {
    let nav = nav_of(snapshot);
    let tag = text(nav, "_tag");
    match role {
        "tabId" => tab_of(snapshot).to_owned(),
        "url" => text(nav, "url").to_owned(),
        "title" => {
            let title = text(nav, "title");
            let url = text(nav, "url");
            if !title.is_empty() {
                title.to_owned()
            } else if url.is_empty() {
                "New tab".to_owned()
            } else {
                url.to_owned()
            }
        }
        "status" => match tag {
            "Loading" => "loading",
            "Success" => "loaded",
            "LoadFailed" => "failed",
            _ => "idle",
        }
        .to_owned(),
        "problem" if tag == "LoadFailed" => nav
            .get("description")
            .and_then(Json::as_str)
            .unwrap_or("The page did not load.")
            .to_owned(),
        _ => String::new(),
    }
}

/// The tab `event` leaves behind, given the tab as it was; none when it
/// closed or never was.
fn after(event: &Json, current: Option<&Json>) -> Option<Json> {
    match text(event, "type") {
        "closed" => None,
        "failed" => {
            let mut failed = event.as_object()?.clone();
            for drop in [
                "type",
                "threadId",
                "tabId",
                "createdAt",
                "serverEpoch",
                "revision",
            ] {
                failed.remove(drop);
            }
            failed.insert("_tag".into(), json!("LoadFailed"));
            let mut snapshot = current?.clone();
            snapshot
                .as_object_mut()?
                .insert("navStatus".into(), Json::Object(failed));
            Some(snapshot)
        }
        _ => match event.get("snapshot") {
            Some(snapshot) if snapshot.is_object() => Some(snapshot.clone()),
            _ => current.cloned(),
        },
    }
}

/// An address as the user typed it, as a web page's URL: QUrl's
/// fromUserInput, for what a browser tab takes (http and https only).
pub fn web_address(address: &str) -> Option<String> {
    let address = address.trim();
    if address.is_empty() || address.starts_with('/') || address.starts_with('~') {
        return None;
    }
    // As QUrl::fromUserInput: an address with its own scheme keeps it
    // (so `mailto:` is not a web page), but `localhost:3000` is a host and
    // port, not a scheme.
    let url = match url::Url::parse(address) {
        Ok(url) if !address[url.scheme().len() + 1..].starts_with(|c: char| c.is_ascii_digit()) => {
            url
        }
        _ => url::Url::parse(&format!("http://{address}")).ok()?,
    };
    (matches!(url.scheme(), "http" | "https") && url.host().is_some()).then(|| url.to_string())
}

fn key_of(tab: &str) -> RowKey {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    tab.hash(&mut hasher);
    hasher.finish()
}

/// A thread's browser tabs.
#[derive(Debug)]
pub struct Previews {
    environment: String,
    thread: String,
    mc: String,
    active: bool,
    following: bool,
    /// Replies for another thread (or an older load) are dropped.
    generation: u64,
    epoch: String,
    revision: i64,
    rows: Vec<Json>,
    /// Tabs being closed: their events do not bring them back.
    closing: HashSet<String>,
    /// A list is on its way; the thread's events since it was asked for,
    /// which it may predate.
    listing: bool,
    early: Vec<Json>,
    /// The MC's machine's web servers: {url, processName}.
    servers: Vec<Json>,
    configured: Vec<String>,
    /// As the owner last read them.
    recents: Vec<String>,
    status: &'static str,
    message: String,
    changes: Vec<RowChange>,
    effects: Vec<Effect>,
    notes: Vec<PreviewNote>,
}

impl Default for Previews {
    fn default() -> Previews {
        Previews {
            environment: String::new(),
            thread: String::new(),
            mc: String::new(),
            active: false,
            following: false,
            generation: 0,
            epoch: String::new(),
            revision: -1,
            rows: Vec::new(),
            closing: HashSet::new(),
            listing: false,
            early: Vec::new(),
            servers: Vec::new(),
            configured: Vec::new(),
            recents: Vec::new(),
            status: "idle",
            message: String::new(),
            changes: Vec::new(),
            effects: Vec::new(),
            notes: Vec::new(),
        }
    }
}

impl Previews {
    pub fn new() -> Previews {
        Previews::default()
    }

    /// The thread shown, and the MC whose events carry its tabs (empty when
    /// none does).
    pub fn set_thread(&mut self, environment: &str, thread: &str, mc: &str) {
        if environment == self.environment && thread == self.thread && mc == self.mc {
            return;
        }
        let moved = environment != self.environment || thread != self.thread;
        environment.clone_into(&mut self.environment);
        thread.clone_into(&mut self.thread);
        if mc != self.mc {
            self.unfollow();
            mc.clone_into(&mut self.mc);
            if !self.servers.is_empty() {
                self.servers.clear();
                self.notes.push(PreviewNote::Suggestions);
            }
        }
        if moved {
            self.generation += 1;
            self.closing.clear();
            self.listing = false;
            self.early.clear();
            if !self.rows.is_empty() {
                self.rows.clear();
                self.changes.push(RowChange::Reset(Vec::new()));
                self.notes.push(PreviewNote::Count);
            }
            self.set_status("idle", "");
        }
        if self.active {
            self.follow();
            if moved {
                self.reload();
            }
        }
    }

    /// Loads and follows while shown; forgets nothing when hidden.
    pub fn set_active(&mut self, active: bool) {
        if active == self.active {
            return;
        }
        self.active = active;
        if active {
            self.follow();
            self.reload();
        } else {
            self.unfollow();
        }
    }

    pub fn active(&self) -> bool {
        self.active
    }

    /// Events sent while the connection was down are lost, and a restarted
    /// MC sends none for what it no longer has.
    pub fn ready_changed(&mut self, ready: bool) {
        if ready && self.active {
            self.reload();
        }
    }

    fn follow(&mut self) {
        if self.following || self.mc.is_empty() {
            return;
        }
        self.following = true;
        self.effects.push(Effect::Follow(self.mc.clone()));
    }

    fn unfollow(&mut self) {
        if std::mem::replace(&mut self.following, false) {
            self.effects.push(Effect::Unfollow);
        }
    }

    /// The preview addresses the thread's project configures (its scripts'
    /// previewUrl).
    pub fn set_configured(&mut self, urls: Vec<String>) {
        if urls == self.configured {
            return;
        }
        self.configured = urls;
        self.notes.push(PreviewNote::Suggestions);
    }

    /// The pages this device opened last, newest first, as kept.
    pub fn set_recents(&mut self, recents: Vec<String>) {
        self.recents = recents;
    }

    /// A `localServers` frame's servers.
    pub fn servers_listed(&mut self, servers: Vec<Json>) {
        if servers == self.servers {
            return;
        }
        self.servers = servers;
        self.notes.push(PreviewNote::Suggestions);
    }

    /// What an empty tab offers: `{url, label, kind}`, kind "server",
    /// "configured" or "recent"; each address once.
    pub fn suggestions(&self) -> Vec<Json> {
        let mut list = Vec::new();
        let mut seen = HashSet::new();
        let mut add = |url: &str, label: &str, kind: &str| {
            if !url.is_empty() && seen.insert(url.to_owned()) {
                list.push(json!({"url": url, "label": label, "kind": kind}));
            }
        };
        for server in &self.servers {
            add(text(server, "url"), text(server, "processName"), "server");
        }
        for url in &self.configured {
            add(url, "", "configured");
        }
        for url in self.recents.iter().take(MAX_RECENTS) {
            add(url, "", "recent");
        }
        list
    }

    /// The first tab with no page yet (what `suggestions` would fill), or
    /// "".
    pub fn empty_tab(&self) -> &str {
        self.rows
            .iter()
            .find(|row| text(nav_of(row), "url").is_empty())
            .map_or("", |row| tab_of(row))
    }

    /// idle, loading, ready or failed: the list itself, not its tabs.
    pub fn status(&self) -> &'static str {
        self.status
    }

    pub fn message(&self) -> &str {
        &self.message
    }

    pub fn count(&self) -> usize {
        self.rows.len()
    }

    pub fn row_of(&self, tab: &str) -> Option<usize> {
        self.rows.iter().position(|row| tab_of(row) == tab)
    }

    fn call(&mut self, method: &'static str, payload: Json, then: Then) {
        self.effects.push(Effect::Call {
            environment: self.environment.clone(),
            method,
            payload,
            then,
        });
    }

    fn notify(&mut self, title: &'static str, description: String) {
        self.effects.push(Effect::Notify { title, description });
    }

    /// An empty tab on the MC.
    pub fn new_tab(&mut self) {
        if self.thread.is_empty() {
            return;
        }
        let payload = json!({"threadId": self.thread});
        let generation = self.generation;
        self.call("preview.open", payload, Then::Open { generation });
    }

    /// Points the tab at `address` and opens the page in the browser.
    pub fn navigate(&mut self, tab: &str, address: &str) {
        let url = web_address(address);
        let (Some(url), Some(_), false) = (url, self.row_of(tab), self.thread.is_empty()) else {
            let description = format!("\"{}\" is not a web address.", address.trim());
            self.notify("Could not open the page", description);
            return;
        };
        let payload = json!({"threadId": self.thread, "tabId": tab, "url": url});
        let generation = self.generation;
        self.call(
            "preview.navigate",
            payload,
            Then::Navigate { generation, url },
        );
    }

    /// Opens the tab's page in the browser.
    pub fn open(&mut self, tab: &str) {
        let Some(row) = self.row_of(tab) else {
            return;
        };
        let url = text(nav_of(&self.rows[row]), "url").to_owned();
        if !url.is_empty() {
            self.effects.push(Effect::Open(url));
        }
    }

    pub fn close(&mut self, tab: &str) {
        let Some(row) = self.row_of(tab) else {
            return;
        };
        if self.thread.is_empty() {
            return;
        }
        let snapshot = self.rows[row].clone();
        self.closing.insert(tab.to_owned());
        self.remove(tab);
        let payload = json!({"threadId": self.thread, "tabId": tab});
        let then = Then::Close {
            row,
            snapshot,
            tab: tab.to_owned(),
        };
        self.call("preview.close", payload, then);
    }

    pub fn reload(&mut self) {
        if self.thread.is_empty() {
            return;
        }
        self.generation += 1;
        self.listing = true;
        // The list reads everything before it.
        self.early.clear();
        if self.rows.is_empty() {
            self.set_status("loading", "");
        }
        let payload = json!({"threadId": self.thread});
        let generation = self.generation;
        self.call("preview.list", payload, Then::List { generation });
    }

    /// The MC's answer to an [`Effect::Call`].
    pub fn answer(&mut self, then: Then, result: Result<Json, String>) {
        match then {
            Then::List { generation } => self.listed(generation, result),
            Then::Open { generation } => {
                if generation != self.generation {
                    return;
                }
                match result {
                    Err(error) => self.notify("Could not open a browser tab", error),
                    // Its `opened` event may be behind the answer.
                    Ok(snapshot) if snapshot.is_object() && self.status == "ready" => {
                        self.upsert(snapshot);
                    }
                    Ok(_) => {}
                }
            }
            Then::Navigate { generation, url } => {
                let snapshot = match result {
                    Err(error) => return self.notify("Could not open the page", error),
                    Ok(snapshot) => snapshot,
                };
                if generation == self.generation && snapshot.is_object() && self.status == "ready" {
                    self.upsert(snapshot);
                }
                let mut recents = std::mem::take(&mut self.recents);
                recents.retain(|r| *r != url);
                recents.insert(0, url.clone());
                recents.truncate(MAX_RECENTS);
                self.recents = recents.clone();
                self.effects.push(Effect::Remember(recents));
                self.notes.push(PreviewNote::Suggestions);
                self.effects.push(Effect::Open(url));
            }
            Then::Close { row, snapshot, tab } => {
                // Another thread, opened since, forgot what it was closing.
                if !self.closing.remove(&tab) {
                    return;
                }
                let Err(error) = result else {
                    return;
                };
                // It is still open on the MC: it comes back where it was.
                if self.row_of(&tab).is_none() {
                    let at = row.min(self.rows.len());
                    self.rows.insert(at, snapshot);
                    self.changes.push(RowChange::Inserted {
                        first: at,
                        keys: vec![key_of(&tab)],
                    });
                    self.notes.push(PreviewNote::Count);
                }
                self.notify("Could not close the browser tab", error);
            }
        }
    }

    fn listed(&mut self, generation: u64, result: Result<Json, String>) {
        if generation != self.generation {
            return;
        }
        self.listing = false;
        let list = match result {
            Err(error) => {
                // What was listed stays; the failure says why it may be
                // stale.
                self.early.clear();
                return self.set_status("failed", &error);
            }
            Ok(list) => list,
        };
        let mut rows: Vec<Json> = list
            .get("sessions")
            .and_then(Json::as_array)
            .into_iter()
            .flatten()
            .filter(|s| !self.closing.contains(tab_of(s)))
            .cloned()
            .collect();
        text(&list, "serverEpoch").clone_into(&mut self.epoch);
        self.revision = revision_of(&list);
        // What changed while the list was on its way, if the list is older:
        // a tab already gone does not come back.
        let mut restarted = false;
        for event in std::mem::take(&mut self.early) {
            if text(&event, "serverEpoch") != self.epoch {
                restarted = true;
                continue;
            }
            let revision = revision_of(&event);
            let tab = tab_of(&event);
            if revision <= self.revision || self.closing.contains(tab) {
                continue;
            }
            self.revision = revision;
            let at = rows.iter().position(|row| tab_of(row) == tab);
            match (after(&event, at.map(|at| &rows[at])), at) {
                (None, Some(at)) => {
                    rows.remove(at);
                }
                (Some(next), Some(at)) => rows[at] = next,
                (Some(next), None) => rows.push(next),
                (None, None) => {}
            }
        }
        let same_tabs = rows.len() == self.rows.len()
            && rows
                .iter()
                .zip(&self.rows)
                .all(|(a, b)| tab_of(a) == tab_of(b));
        if same_tabs {
            // The same tabs: only those that read differently repaint.
            for row in rows {
                self.upsert(row);
            }
        } else {
            let counted = rows.len() != self.rows.len();
            self.changes.push(RowChange::Reset(
                rows.iter().map(|r| key_of(tab_of(r))).collect(),
            ));
            self.rows = rows;
            if counted {
                self.notes.push(PreviewNote::Count);
            }
        }
        self.set_status("ready", "");
        if restarted {
            self.reload();
        }
    }

    /// A `preview` frame's event.
    pub fn on_event(&mut self, event: &Json) {
        if text(event, "threadId") != self.thread {
            return;
        }
        if self.listing {
            self.early.push(event.clone());
        }
        if self.status != "ready" {
            return;
        }
        if text(event, "serverEpoch") != self.epoch {
            // The MC restarted: its tabs are whatever it lists now.
            return self.reload();
        }
        let revision = revision_of(event);
        if revision <= self.revision {
            return;
        }
        self.revision = revision;
        let tab = tab_of(event);
        if self.closing.contains(tab) {
            return;
        }
        let current = self.row_of(tab).map(|row| &self.rows[row]);
        match after(event, current) {
            Some(next) => self.upsert(next),
            None => self.remove(tab),
        }
    }

    fn set_status(&mut self, status: &'static str, message: &str) {
        if status == self.status && message == self.message {
            return;
        }
        self.status = status;
        message.clone_into(&mut self.message);
        self.notes.push(PreviewNote::Status);
    }

    fn upsert(&mut self, snapshot: Json) {
        let tab = tab_of(&snapshot).to_owned();
        if let Some(row) = self.row_of(&tab) {
            if self.rows[row] == snapshot {
                return;
            }
            // Fields no role shows change without a repaint.
            let redraw = ROLES
                .iter()
                .any(|role| shown(&self.rows[row], role) != shown(&snapshot, role));
            self.rows[row] = snapshot;
            if redraw {
                self.changes.push(RowChange::Changed {
                    first: row,
                    count: 1,
                    roles: &[],
                });
            }
            return;
        }
        self.rows.push(snapshot);
        self.changes.push(RowChange::Inserted {
            first: self.rows.len() - 1,
            keys: vec![key_of(&tab)],
        });
        self.notes.push(PreviewNote::Count);
    }

    fn remove(&mut self, tab: &str) {
        let Some(row) = self.row_of(tab) else {
            return;
        };
        self.rows.remove(row);
        self.changes.push(RowChange::Removed {
            first: row,
            count: 1,
        });
        self.notes.push(PreviewNote::Count);
    }

    pub fn take_effects(&mut self) -> Vec<Effect> {
        std::mem::take(&mut self.effects)
    }

    pub fn take_notes(&mut self) -> Vec<PreviewNote> {
        std::mem::take(&mut self.notes)
    }
}

impl RowSource for Previews {
    fn roles(&self) -> &'static [&'static str] {
        ROLES
    }

    fn row_count(&self) -> usize {
        self.rows.len()
    }

    fn row_key(&self, row: usize) -> RowKey {
        self.rows
            .get(row)
            .map_or(row as RowKey, |r| key_of(tab_of(r)))
    }

    fn data(&self, row: usize, role: &str) -> Value {
        match self.rows.get(row) {
            Some(snapshot) if ROLES.contains(&role) => Value::from(shown(snapshot, role).as_str()),
            _ => Value::Undefined,
        }
    }

    fn take_changes(&mut self) -> Vec<RowChange> {
        std::mem::take(&mut self.changes)
    }
}

/// An error toast: type, title, description.
pub type Notify = Rc<dyn Fn(&Engine, &str, &str, &str)>;
/// A page for the user's browser.
pub type Open = Rc<dyn Fn(&Engine, &str)>;
/// The pages this device opened last, newest first: read, and written.
pub type ReadRecents = Rc<dyn Fn(&Engine) -> Vec<String>>;
pub type WriteRecents = Rc<dyn Fn(&Engine, &[String])>;

struct Inner {
    rows: Rc<ListRows<Previews>>,
    mc: Rc<dyn Mc>,
    notify: Notify,
    open: Open,
    recents: RefCell<Option<(ReadRecents, WriteRecents)>>,
    /// localServers, then preview.
    subscriptions: RefCell<Option<(SubId, SubId)>>,
}

impl Drop for Inner {
    fn drop(&mut self) {
        if let Some((servers, events)) = self.subscriptions.get_mut().take() {
            self.mc.unsubscribe(servers);
            self.mc.unsubscribe(events);
        }
    }
}

impl std::fmt::Debug for Inner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ThreadPreviews")
            .field("rows", &self.rows)
            .finish_non_exhaustive()
    }
}

/// A thread's browser tabs: the Previews tab.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "ThreadPreviews", uncreatable)]
pub struct ThreadPreviews {
    #[qml(readonly, notify)]
    count: i32,
    /// idle, loading, ready or failed: the list itself, not its tabs.
    #[qml(readonly, notify)]
    status: Atom,
    #[qml(readonly, notify)]
    message: Atom,
    /// What an empty tab offers: [{url, label, kind}].
    #[qml(readonly, notify)]
    suggestions: Value,
    /// The first tab with no page yet, or "".
    #[qml(readonly, notify)]
    empty_tab: Atom,
    #[qml(skip)]
    inner: Rc<Inner>,
}

fn inner_of(engine: &Engine, obj: ObjectId) -> Option<Rc<Inner>> {
    engine
        .with::<ThreadPreviews, _>(obj, |p| p.inner.clone())
        .ok()
}

impl ThreadPreviews {
    /// The previews owned by `owner`, asking `mc`; `notify` raises an error
    /// toast and `open` hands a page to the browser.
    pub fn create(
        engine: &Engine,
        owner: Option<ObjectId>,
        mc: Rc<dyn Mc>,
        notify: impl Fn(&Engine, &str, &str, &str) + 'static,
        open: impl Fn(&Engine, &str) + 'static,
    ) -> Result<ObjectId, EngineError> {
        let rows = ListRows::new(Previews::new());
        let inner = Rc::new(Inner {
            rows: rows.clone(),
            mc: mc.clone(),
            notify: Rc::new(notify),
            open: Rc::new(open),
            recents: RefCell::new(None),
            subscriptions: RefCell::new(None),
        });
        let previews = ThreadPreviews {
            count: 0,
            status: Atom::new("idle"),
            message: Atom::new(""),
            suggestions: Value::Undefined,
            empty_tab: Atom::new(""),
            inner,
        };
        let obj = engine.create_native(previews, owner)?;
        rows.attach(engine, obj)?;
        mc.on_ready_changed(Box::new(move |engine, ready| {
            ThreadPreviews::update(engine, obj, |p| p.ready_changed(ready));
        }));
        tell_suggestions(engine, obj, &rows);
        Ok(obj)
    }

    /// Where the pages this device opened last are kept: the device setting
    /// `previewRecentPages` (`Settings::device_value`, `write_device`).
    // TODO(port): RightPanelController::RightPanelController — it passes them.
    pub fn set_recents(
        engine: &Engine,
        obj: ObjectId,
        read: impl Fn(&Engine) -> Vec<String> + 'static,
        write: impl Fn(&Engine, &[String]) + 'static,
    ) {
        if let Some(inner) = inner_of(engine, obj) {
            *inner.recents.borrow_mut() = Some((Rc::new(read), Rc::new(write)));
            ThreadPreviews::update(engine, obj, |p| p.notes.push(PreviewNote::Suggestions));
        }
    }

    /// Runs `f` on the previews of `obj`, then tells the views and the
    /// properties what it changed and asks the MC what it said to. None when
    /// `obj` is not live.
    pub fn update<R>(
        engine: &Engine,
        obj: ObjectId,
        f: impl FnOnce(&mut Previews) -> R,
    ) -> Option<R> {
        let inner = inner_of(engine, obj)?;
        let recents = inner
            .recents
            .borrow()
            .as_ref()
            .map(|(read, _)| read.clone());
        let recents = recents.map(|read| read(engine)).unwrap_or_default();
        let (result, notes, effects) = inner.rows.update(engine, |p| {
            p.set_recents(recents);
            let result = f(p);
            (result, p.take_notes(), p.take_effects())
        });
        tell(engine, obj, &inner, &notes);
        for effect in effects {
            run(engine, obj, &inner, effect);
        }
        Some(result)
    }

    /// Reads the previews of `obj`. `f` must not call back into them.
    pub fn read<R>(engine: &Engine, obj: ObjectId, f: impl FnOnce(&Previews) -> R) -> Option<R> {
        Some(inner_of(engine, obj)?.rows.read(f))
    }
}

fn warn(engine: &Engine, result: Result<(), EngineError>) {
    if let Err(e) = result {
        engine.log(
            ljos::prelude::LogLevel::Warning,
            "ThreadPreviews",
            e.to_string(),
        );
    }
}

fn tell_suggestions(engine: &Engine, obj: ObjectId, rows: &ListRows<Previews>) {
    let suggestions = rows.read(Previews::suggestions);
    let value = Json::Array(suggestions).to_value();
    warn(
        engine,
        engine.set_internal(obj, ThreadPreviews::SUGGESTIONS, value),
    );
}

fn tell(engine: &Engine, obj: ObjectId, inner: &Inner, notes: &[PreviewNote]) {
    let (count, status, message, empty) = inner.rows.read(|p| {
        (
            int(p.count()),
            Atom::new(p.status()),
            Atom::new(p.message()),
            Atom::new(p.empty_tab()),
        )
    });
    let mut result = engine.set_internal(obj, ThreadPreviews::EMPTY_TAB, empty);
    for note in notes {
        result = result.and_then(|()| match note {
            PreviewNote::Count => engine.set_internal(obj, ThreadPreviews::COUNT, count),
            PreviewNote::Status => engine
                .set_internal(obj, ThreadPreviews::STATUS, status.clone())
                .and_then(|()| engine.set_internal(obj, ThreadPreviews::MESSAGE, message.clone())),
            PreviewNote::Suggestions => Ok(()),
        });
    }
    warn(engine, result);
    if notes.contains(&PreviewNote::Suggestions) {
        tell_suggestions(engine, obj, &inner.rows);
    }
}

fn run(engine: &Engine, obj: ObjectId, inner: &Inner, effect: Effect) {
    match effect {
        Effect::Follow(mc) => {
            // The servers on the MC's machine, not this one's: the MC scans
            // while someone watches.
            let servers = inner.mc.subscribe(
                json!({"type": "localServers", "mc": mc}),
                Box::new(move |engine, frame| {
                    if frame.get("t").and_then(Json::as_str) != Some("localServers") {
                        return;
                    }
                    let servers = frame
                        .get("list")
                        .and_then(|l| l.get("servers"))
                        .and_then(Json::as_array)
                        .cloned()
                        .unwrap_or_default();
                    ThreadPreviews::update(engine, obj, |p| p.servers_listed(servers));
                }),
                None,
            );
            let events = inner.mc.subscribe(
                json!({"type": "preview", "mc": mc}),
                Box::new(move |engine, frame| {
                    let event = frame.get("event").cloned().unwrap_or(Json::Null);
                    ThreadPreviews::update(engine, obj, |p| p.on_event(&event));
                }),
                None,
            );
            *inner.subscriptions.borrow_mut() = Some((servers, events));
        }
        Effect::Unfollow => {
            let subscriptions = inner.subscriptions.borrow_mut().take();
            if let Some((servers, events)) = subscriptions {
                inner.mc.unsubscribe(servers);
                inner.mc.unsubscribe(events);
            }
        }
        Effect::Call {
            environment,
            method,
            payload,
            then,
        } => inner.mc.call(
            &environment,
            method,
            payload,
            Box::new(move |engine, result: Result<Json, McError>| {
                let result = result.map_err(|e| e.message);
                ThreadPreviews::update(engine, obj, |p| p.answer(then, result));
            }),
        ),
        Effect::Notify { title, description } => {
            (inner.notify)(engine, "error", title, &description);
        }
        Effect::Open(url) => (inner.open)(engine, &url),
        Effect::Remember(urls) => {
            let write = inner.recents.borrow().as_ref().map(|(_, w)| w.clone());
            if let Some(write) = write {
                write(engine, &urls);
            }
        }
    }
}

#[qml_impl]
impl ThreadPreviews {
    #[qml(invokable)]
    fn reload(cx: &Cx) {
        ThreadPreviews::update(cx.engine, cx.this, Previews::reload);
    }

    /// Opens the tab's page in the browser.
    #[qml(invokable)]
    fn open(cx: &Cx, tab_id: Atom) {
        ThreadPreviews::update(cx.engine, cx.this, |p| p.open(&tab_id));
    }

    #[qml(invokable)]
    fn close(cx: &Cx, tab_id: Atom) {
        ThreadPreviews::update(cx.engine, cx.this, |p| p.close(&tab_id));
    }

    /// An empty tab on the MC.
    #[qml(invokable)]
    fn new_tab(cx: &Cx) {
        ThreadPreviews::update(cx.engine, cx.this, Previews::new_tab);
    }

    /// Points the tab at `url` and opens the page in the browser.
    #[qml(invokable)]
    fn navigate(cx: &Cx, tab_id: Atom, url: Atom) {
        ThreadPreviews::update(cx.engine, cx.this, |p| p.navigate(&tab_id, &url));
    }
}

#[cfg(test)]
#[path = "previews_tests.rs"]
mod tests;
