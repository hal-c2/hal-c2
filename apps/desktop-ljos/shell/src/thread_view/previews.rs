//! desktop-qt's ThreadPreviews: the Previews tab, a thread's browser tabs
//! as the MC keeps them (`preview.list`), each opened in the user's browser
//! rather than embedded. While shown it follows the MC's `preview` events
//! (the MC serving the thread's environment).
//!
//! `close(tabId)` is `preview.close`: the row goes at once and stays gone
//! while the close is in flight; a close that fails brings it back where it
//! was, unless a list since says the MC no longer has it.
//!
//! `newTab()` is `preview.open` with no address: an empty tab the user
//! fills from `suggestions`: the web servers listening on the MC's machine
//! (its `localServers` shape, followed only while the list shows), the
//! project's configured preview addresses and the pages this device opened
//! last. `navigate(tabId, url)` is `preview.navigate`, and opens the page in
//! the browser. Each page a tab of the thread loads joins the project's
//! history on this device ([`PreviewHistory`]), which `forget(url)` takes a
//! page off.
//!
//! Embedded (`set_embedded`, the desktop with its in-app browser): each tab
//! is a page in the panel (BrowserPage) rather than the user's browser. The
//! tabs are followed while a thread shows at all; the MC's machine's servers
//! only while `suggesting`. `navigate` points the tab at the page without
//! opening it elsewhere, and a dev server's address (`openAddress`) opens in
//! a tab of its own, or the one already showing it (`showRequested`). A page
//! reports how it loads ([`Previews::report`], `preview.reportStatus`) and the
//! size it is shown at ([`Previews::resize_tab`]).
//!
//! A page opens with `openAddress(url)`: a dev server's loopback address on
//! a thread of another cluster MC opens through the port the connected MC
//! forwards to it (`preview.forward`), its path, query and fragment kept.
//! The thread's MC forwards only a port one of its tabs names, so an address
//! no tab names (a link in a reply) opens a tab for it first. Only a
//! connected MC on this machine forwards to this machine's loopback; with
//! one elsewhere the address opens as it is.
//!
//! [`Previews`] is the core: it takes events, frames and replies and says
//! what to ask of the MC as [`Effect`]s. [`ThreadPreviews`] is the object
//! QML binds; it runs those effects on the shell's MC.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::hash::{Hash, Hasher};
use std::rc::Rc;

use ljos::prelude::QmlValue;
use ljos::prelude::{Atom, Cx, Engine, ObjectId, QmlObject, Value, qml_impl};
use ljos::prelude::{EngineError, RowKey};
use serde_json::json;

use super::preview_history::{self, PreviewHistory, TIMED_SINCE};
use super::rows::{ListRows, RowChange, RowSource, int};
use crate::json::Json;
use crate::mc::{Mc, McError, SubId};

pub const ROLES: &[&str] = &["tabId", "url", "title", "status", "problem"];

/// The pages of the project a new tab offers, its newest visits.
pub const MAX_RECENTS: usize = 10;

/// The thread a page opens for, as it was when the user asked: another may
/// show by the time the MC answers.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct For {
    pub environment: String,
    pub thread: String,
    pub mc: String,
}

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
        to: For,
    },
    /// The thread's tabs, to find one at the address's port.
    ListFor {
        url: String,
        to: For,
    },
    /// A tab opened for the address, so its MC forwards the port.
    OpenFor {
        generation: u64,
        url: String,
        to: For,
    },
    /// The connected MC's forward to the address's port.
    Forward {
        url: String,
        port: u16,
    },
    /// Embedded: a tab opened for an address, to show.
    Show {
        generation: u64,
        to: For,
    },
    /// The row the tab was at, to bring it back.
    Close {
        row: usize,
        tab: String,
    },
    /// A page's report: its answer is [`Effect::Heard`] with `id`.
    Report {
        id: u64,
    },
    /// A tab's resize: its answer is [`Effect::Resized`] with `id`.
    Resize {
        id: u64,
    },
}

/// What the previews ask of their owner, in order.
#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    /// Follow this MC's `preview` shape.
    Follow(String),
    Unfollow,
    /// Follow this MC's `localServers` shape: the servers a new tab offers.
    FollowServers(String),
    UnfollowServers,
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
    /// The pages this device's tabs visited ([`PreviewHistory::to_json`]),
    /// to keep.
    KeepHistory(Json),
    /// How the MC took report `id` ([`Previews::report`]).
    Heard {
        id: u64,
        unheard: Unheard,
    },
    /// The MC answered resize `id` ([`Previews::resize_tab`]), with why it
    /// refused.
    Resized {
        id: u64,
        error: Option<String>,
    },
}

/// What changed besides the rows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PreviewNote {
    Count,
    /// status or message.
    Status,
    Suggestions,
    /// The tab's snapshot changed, came or went (`tabChanged`).
    Tab(String),
    /// A list was read (`listed`).
    Listed,
    /// Embedded: the panel shows this tab (`showRequested`).
    Show(String),
}

/// How the MC took a page's report ([`Previews::report`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Unheard {
    /// The MC refused it: the page goes back to its tab.
    Refused,
    /// It never left: the connection was down.
    Unsent,
    /// It may have reached the MC, or not: a connection that went with it
    /// written, a member out of reach, a timeout.
    Dropped,
    Heard,
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

/// When the MC last changed the tab (`updatedAt`), ms since the epoch; 0
/// when it does not say.
fn stamp_of(snapshot: &Json) -> i64 {
    crate::sidebar_model::parse_iso(snapshot.get("updatedAt").and_then(Json::as_str)).unwrap_or(0)
}

/// The page the tab has loaded, or "".
fn loaded_url(snapshot: &Json) -> &str {
    let nav = nav_of(snapshot);
    if text(nav, "_tag") == "Success" {
        text(nav, "url")
    } else {
        ""
    }
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

/// Whether embedded `open_address` shows `url` in a tab here: a dev
/// server's (loopback) web address.
pub fn opens_here(url: &str) -> bool {
    url::Url::parse(url).is_ok_and(|url| loopback(&url))
}

/// A dev server's address on the machine it names: one only that machine
/// reaches.
fn loopback(url: &url::Url) -> bool {
    matches!(url.scheme(), "http" | "https")
        && url
            .host_str()
            .is_some_and(crate::this_machine::loopback_host)
}

fn port_of(url: &url::Url) -> u16 {
    url.port()
        .unwrap_or(if url.scheme() == "https" { 443 } else { 80 })
}

/// Whether one of `tabs` is at a loopback address at `port`.
fn names_port(tabs: &[Json], port: u16) -> bool {
    tabs.iter().any(|tab| {
        url::Url::parse(text(nav_of(tab), "url"))
            .is_ok_and(|at| loopback(&at) && port_of(&at) == port)
    })
}

/// `url` at the forward's `port`. The forward listens at 127.0.0.1 (and at
/// ::1 only where this machine has IPv6), never at 127.0.0.1's aliases, so
/// an address by number goes there; `localhost` stays.
fn forwarded(url: &str, port: u16) -> String {
    let Ok(mut url) = url::Url::parse(url) else {
        return url.to_owned();
    };
    let by_number = matches!(url.host(), Some(url::Host::Ipv4(_) | url::Host::Ipv6(_)));
    // Neither fails for an http(s) address with a host, which a forward is
    // only asked for.
    let _ = url.set_port(Some(port));
    if by_number {
        let _ = url.set_host(Some("127.0.0.1"));
    }
    url.to_string()
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
    /// Tabs being closed, as their events have left them: hidden, and
    /// brought back as they are now if the MC refuses. One the MC closes
    /// meanwhile is forgotten.
    closing: HashMap<String, Json>,
    /// A list is on its way; the thread's events since it was asked for,
    /// which it may predate.
    listing: bool,
    early: Vec<Json>,
    /// The MC's machine's web servers: {url, processName}.
    servers: Vec<Json>,
    following_servers: bool,
    configured: Vec<String>,
    /// The device's history as the owner last read it; none without a store.
    history: Option<PreviewHistory>,
    /// The project the thread is in, whose pages the history keeps.
    project: String,
    /// The newest `updatedAt` the MC has sent: when a page taken off the
    /// list was taken off, on the MC's clock.
    newest_stamp: i64,
    /// The wall clock, as the owner last read it: when a page with no
    /// `updatedAt` loaded.
    now: i64,
    embedded: bool,
    suggesting: bool,
    /// The kind of event that last changed each tab; none when a list did.
    last_event: HashMap<String, String>,
    /// A report went unanswered: the next event lists the tabs again.
    unreached: bool,
    /// The environment the shell is connected to, and whether its MC runs
    /// on this machine, as the owner last read them.
    connected: String,
    connected_here: bool,
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
            closing: HashMap::new(),
            listing: false,
            early: Vec::new(),
            servers: Vec::new(),
            following_servers: false,
            configured: Vec::new(),
            history: None,
            project: String::new(),
            newest_stamp: 0,
            now: 0,
            embedded: false,
            suggesting: false,
            last_event: HashMap::new(),
            unreached: false,
            connected: String::new(),
            connected_here: true,
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
        // Another MC's clock: a removal falls back to the kept page's time
        // until this one's stamps arrive.
        if environment != self.environment || mc != self.mc {
            self.newest_stamp = 0;
        }
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
            // Not ready before the rows go: what follows the tabs keeps them
            // until the new thread's are listed.
            self.set_status("idle", "");
            if !self.rows.is_empty() {
                let gone = std::mem::take(&mut self.rows);
                self.changes.push(RowChange::Reset(Vec::new()));
                self.notes.push(PreviewNote::Count);
                for row in &gone {
                    self.notes.push(PreviewNote::Tab(tab_of(row).to_owned()));
                }
            }
        }
        if self.active {
            self.follow();
            if moved {
                self.reload();
            }
        }
    }

    /// The environment and thread shown.
    pub fn environment(&self) -> &str {
        &self.environment
    }

    pub fn thread(&self) -> &str {
        &self.thread
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

    /// Pages open in the app's own browser (the module doc).
    pub fn set_embedded(&mut self, embedded: bool) {
        if embedded != self.embedded {
            self.embedded = embedded;
            self.follow_servers_if_wanted();
        }
    }

    pub fn embedded(&self) -> bool {
        self.embedded
    }

    /// Embedded, the MC's machine's servers are followed only while an empty
    /// tab or the overview offers them.
    pub fn set_suggesting(&mut self, suggesting: bool) {
        if suggesting != self.suggesting {
            self.suggesting = suggesting;
            self.follow_servers_if_wanted();
        }
    }

    fn wants_servers(&self) -> bool {
        self.active && (!self.embedded || self.suggesting)
    }

    fn follow_servers_if_wanted(&mut self) {
        if self.wants_servers() {
            self.follow_servers();
        } else {
            self.unfollow_servers();
        }
    }

    fn follow(&mut self) {
        if self.wants_servers() {
            self.follow_servers();
        }
        if self.following || self.mc.is_empty() {
            return;
        }
        self.following = true;
        self.effects.push(Effect::Follow(self.mc.clone()));
    }

    fn unfollow(&mut self) {
        self.unfollow_servers();
        if std::mem::replace(&mut self.following, false) {
            self.effects.push(Effect::Unfollow);
        }
    }

    fn follow_servers(&mut self) {
        if self.following_servers || self.mc.is_empty() {
            return;
        }
        self.following_servers = true;
        self.effects.push(Effect::FollowServers(self.mc.clone()));
    }

    fn unfollow_servers(&mut self) {
        if std::mem::replace(&mut self.following_servers, false) {
            self.effects.push(Effect::UnfollowServers);
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

    /// The environment the shell is connected to, and whether its MC runs on
    /// this machine (without a way to tell, it counts as here).
    pub fn set_connection(&mut self, connected: &str, here: bool) {
        if connected != self.connected {
            connected.clone_into(&mut self.connected);
        }
        self.connected_here = here;
    }

    /// The device's history as kept, or none where nothing keeps it.
    pub fn set_history(&mut self, history: Option<PreviewHistory>) {
        if history != self.history {
            self.history = history;
            self.notes.push(PreviewNote::Suggestions);
        }
    }

    /// The project the thread is in, whose history the suggestions show and
    /// visits join.
    pub fn set_project(&mut self, project: &str) {
        if project != self.project {
            project.clone_into(&mut self.project);
            self.notes.push(PreviewNote::Suggestions);
        }
    }

    /// The wall clock, ms since the epoch.
    pub fn set_now(&mut self, now: i64) {
        self.now = now;
    }

    /// When the tab's page loaded: its `updatedAt`, else now.
    fn loaded_at(&self, snapshot: &Json) -> i64 {
        match stamp_of(snapshot) {
            at if at > 0 => at,
            _ => self.now,
        }
    }

    /// Changes the history and, if that changed it, keeps it.
    fn keep(&mut self, change: impl FnOnce(&mut PreviewHistory, &str) -> bool) {
        if self.project.is_empty() {
            return;
        }
        let Some(history) = self.history.as_mut() else {
            return;
        };
        if !change(history, &self.project) {
            return;
        }
        self.effects.push(Effect::KeepHistory(history.to_json()));
        self.notes.push(PreviewNote::Suggestions);
    }

    /// The pages `snapshots` show join the history: as visits when they
    /// loaded just now, else as pages seen again.
    fn remember(&mut self, snapshots: &[Json], loaded: bool) {
        for snapshot in snapshots {
            self.newest_stamp = self.newest_stamp.max(stamp_of(snapshot));
        }
        let pages: Vec<(String, String, i64)> = snapshots
            .iter()
            .filter(|snapshot| text(nav_of(snapshot), "_tag") == "Success")
            .map(|snapshot| {
                let nav = nav_of(snapshot);
                let at = self.loaded_at(snapshot);
                (
                    text(nav, "url").to_owned(),
                    text(nav, "title").to_owned(),
                    at,
                )
            })
            .collect();
        if pages.is_empty() {
            return;
        }
        self.keep(|history, project| {
            let mut changed = false;
            for (url, title, at) in &pages {
                changed |= if loaded {
                    history.visit(project, url, title, *at)
                } else {
                    history.seen(project, url, title, *at)
                };
            }
            changed
        });
    }

    /// Takes the page off the project's recent pages.
    pub fn forget(&mut self, url: &str) {
        // Timed on the MC's clock, as visits are: a later load brings the
        // page back whatever this device's clock says, and nothing the MC
        // said so far does.
        let at = self.newest_stamp;
        self.keep(|history, project| history.remove(project, url, at));
    }

    /// A `localServers` frame's servers.
    pub fn servers_listed(&mut self, servers: Vec<Json>) {
        if servers == self.servers {
            return;
        }
        self.servers = servers;
        self.notes.push(PreviewNote::Suggestions);
    }

    /// What an empty tab offers: `{url, label, kind, title, detail}`, kind
    /// "server", "configured" or "recent", a recent page also with
    /// `visitedAt` (ms since the epoch); each page once, whatever its anchor.
    pub fn suggestions(&self) -> Vec<Json> {
        let mut list = Vec::new();
        let mut seen = HashSet::new();
        let mut add = |url: &str, label: &str, kind: &str, title: &str, visited: Option<i64>| {
            let tidy = preview_history::tidy(url);
            // A page is one suggestion whatever its anchor: the first one's.
            let key = match tidy.split_once('#') {
                _ if tidy.is_empty() => url.to_owned(),
                Some((page, _)) => page.to_owned(),
                None => tidy.clone(),
            };
            if url.is_empty() || !seen.insert(key) {
                return;
            }
            let shown = preview_history::shown(if tidy.is_empty() { url } else { &tidy });
            let title = if title.is_empty() { &shown } else { title };
            let mut row = json!({
                "url": url, "label": label, "kind": kind, "title": title, "detail": shown,
            });
            if let Some(at) = visited {
                row["visitedAt"] = json!(at);
            }
            list.push(row);
        };
        for server in &self.servers {
            let process = text(server, "processName");
            let title = if process.is_empty() {
                "Listening"
            } else {
                process
            };
            add(text(server, "url"), process, "server", title, None);
        }
        for url in &self.configured {
            add(url, "", "configured", "", None);
        }
        if !self.project.is_empty()
            && let Some(history) = &self.history
        {
            for page in history.pages(&self.project).iter().take(MAX_RECENTS) {
                let visited = (page.at >= TIMED_SINCE).then_some(page.at);
                add(&page.url, "", "recent", &page.title, visited);
            }
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

    /// The MC's tabs, in its order.
    pub fn tab_ids(&self) -> Vec<String> {
        self.rows.iter().map(|row| tab_of(row).to_owned()).collect()
    }

    pub fn row_of(&self, tab: &str) -> Option<usize> {
        self.rows.iter().position(|row| tab_of(row) == tab)
    }

    fn call(&mut self, method: &'static str, payload: Json, then: Then) {
        let environment = self.environment.clone();
        self.call_at(environment, method, payload, then);
    }

    fn call_at(&mut self, environment: String, method: &'static str, payload: Json, then: Then) {
        self.effects.push(Effect::Call {
            environment,
            method,
            payload,
            then,
        });
    }

    /// The thread shown, as a page opens for it.
    fn shown_for(&self) -> For {
        For {
            environment: self.environment.clone(),
            thread: self.thread.clone(),
            mc: self.mc.clone(),
        }
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
        let to = self.shown_for();
        self.call(
            "preview.navigate",
            payload,
            Then::Navigate {
                generation,
                url,
                to,
            },
        );
    }

    /// Opens the tab's page in the browser.
    pub fn open(&mut self, tab: &str) {
        let Some(row) = self.row_of(tab) else {
            return;
        };
        let url = text(nav_of(&self.rows[row]), "url").to_owned();
        if !url.is_empty() {
            self.open_address(&url);
        }
    }

    /// Opens a page the shell itself names (a file the viewer hands over):
    /// through a tab of the thread shown, as `open_address` opens one.
    pub fn open_page(&mut self, url: &str) {
        let to = self.shown_for();
        let named = self.port_named(url, &self.rows);
        self.open_through_tab(url, to, named);
    }

    /// Opens `address` in the browser, for the thread shown: through the
    /// connected MC's forward when it is a dev server on the thread's
    /// machine, another MC's.
    pub fn open_address(&mut self, address: &str) {
        let to = self.shown_for();
        // Embedded, a dev server on the thread's machine opens in a tab here:
        // the one showing it, else a new one. Another MC's machine's goes
        // through its forward to the user's browser, as below.
        if self.embedded
            && opens_here(address)
            && !self.thread.is_empty()
            && !self.forwards(address, &to)
        {
            return self.show_address(address);
        }
        if !self.forwards(address, &to) {
            self.effects.push(Effect::Open(address.to_owned()));
            return;
        }
        // The rows are the thread's tabs only while they are followed;
        // otherwise the MC says which there are.
        if self.active && !self.listing && self.status == "ready" {
            let named = self.port_named(address, &self.rows);
            return self.open_through_tab(address, to, named);
        }
        let payload = json!({"threadId": to.thread});
        let then = Then::ListFor {
            url: address.to_owned(),
            to,
        };
        self.call("preview.list", payload, then);
    }

    /// Embedded: shows the tab at `address`, else opens one for it.
    fn show_address(&mut self, address: &str) {
        // Rows being listed again (after a reconnect, say), or that a list
        // failed to read again, may be tabs the MC no longer has.
        let listed = self.status == "ready" && !self.listing;
        let same = |url: &str| {
            let tidy = |url: &str| {
                url::Url::parse(url).map(|u| u.to_string().trim_end_matches('/').to_owned())
            };
            tidy(url).is_ok_and(|url| Ok(url) == tidy(address))
        };
        if listed && let Some(row) = self.rows.iter().find(|row| same(text(nav_of(row), "url"))) {
            let tab = tab_of(row).to_owned();
            return self.notes.push(PreviewNote::Show(tab));
        }
        let url = url::Url::parse(address).map_or_else(|_| address.to_owned(), |u| u.to_string());
        let payload = json!({"threadId": self.thread, "url": url});
        let then = Then::Show {
            generation: self.generation,
            to: self.shown_for(),
        };
        self.call("preview.open", payload, then);
    }

    /// Embedded: shows the tab in the panel (`showRequested`).
    pub fn show(&mut self, tab: &str) {
        if self.row_of(tab).is_some() {
            self.notes.push(PreviewNote::Show(tab.to_owned()));
        }
    }

    /// The tab as the MC last said, or null when there is none.
    pub fn tab(&self, tab: &str) -> Json {
        self.row_of(tab)
            .map_or(Json::Null, |row| self.rows[row].clone())
    }

    /// The kind of MC event ("navigated", "resized", ...) that last changed
    /// the tab, "" when a list did: what a page reads to tell a report's
    /// echo from news that is not about its address.
    pub fn last_event(&self, tab: &str) -> &str {
        self.last_event.get(tab).map_or("", String::as_str)
    }

    /// What the page showing the tab did: `preview.reportStatus`, `nav` a
    /// PreviewNavStatus. Its answer is [`Effect::Heard`] with `id`; false
    /// (and none comes) when no call was made.
    pub fn report(&mut self, tab: &str, nav: Json, back: bool, forward: bool, id: u64) -> bool {
        if self.row_of(tab).is_none() || self.thread.is_empty() || self.closing.contains_key(tab) {
            return false;
        }
        // The MC's event says it back.
        let payload = json!({
            "threadId": self.thread, "tabId": tab, "navStatus": nav,
            "canGoBack": back, "canGoForward": forward,
        });
        self.call("preview.reportStatus", payload, Then::Report { id });
        true
    }

    /// The size the tab's page is shown at: `preview.resize`, `viewport` a
    /// PreviewViewportSetting. Its answer is [`Effect::Resized`] with `id`;
    /// the tab changes with the MC's event.
    pub fn resize_tab(&mut self, tab: &str, viewport: Json, id: u64) {
        if self.row_of(tab).is_none() || self.thread.is_empty() {
            let error = Some("no such tab".to_owned());
            return self.effects.push(Effect::Resized { id, error });
        }
        // The tab's new size comes in the MC's `resized` event, in order
        // with the rest; the answer's snapshot may be older than an event
        // read before it.
        let payload = json!({"threadId": self.thread, "tabId": tab, "viewport": viewport});
        self.call("preview.resize", payload, Then::Resize { id });
    }

    /// Whether one of `tabs` names `address`'s port.
    fn port_named(&self, address: &str, tabs: &[Json]) -> bool {
        url::Url::parse(address).is_ok_and(|url| names_port(tabs, port_of(&url)))
    }

    /// [`Self::open_for`] when a tab of the thread names the port (`named`),
    /// or once one is opened for it.
    fn open_through_tab(&mut self, url: &str, to: For, named: bool) {
        if named {
            return self.open_for(url, &to);
        }
        let payload = json!({"threadId": to.thread, "url": url});
        let then = Then::OpenFor {
            generation: self.generation,
            url: url.to_owned(),
            to: to.clone(),
        };
        self.call_at(to.environment, "preview.open", payload, then);
    }

    /// Whether `url` opens through a forward: a loopback address for a
    /// thread on another MC of the cluster than the connected one, which
    /// runs here. Any other opens as it is: one on the connected MC, or on
    /// none the cluster knows, and any when the connected MC is on another
    /// machine, where its forward would listen.
    fn forwards(&self, url: &str, to: &For) -> bool {
        url::Url::parse(url).is_ok_and(|url| loopback(&url))
            && !to.thread.is_empty()
            && !to.mc.is_empty()
            && !self.connected.is_empty()
            && to.environment != self.connected
            && self.connected_here
    }

    fn open_for(&mut self, url: &str, to: &For) {
        if !self.forwards(url, to) {
            self.effects.push(Effect::Open(url.to_owned()));
            return;
        }
        let Ok(parsed) = url::Url::parse(url) else {
            return;
        };
        let port = port_of(&parsed);
        let payload = json!({"environmentId": to.environment, "threadId": to.thread, "port": port});
        let then = Then::Forward {
            url: url.to_owned(),
            port,
        };
        let connected = self.connected.clone();
        self.call_at(connected, "preview.forward", payload, then);
    }

    pub fn close(&mut self, tab: &str) {
        let Some(row) = self.row_of(tab) else {
            return;
        };
        if self.thread.is_empty() {
            return;
        }
        self.closing.insert(tab.to_owned(), self.rows[row].clone());
        self.remove(tab);
        let payload = json!({"threadId": self.thread, "tabId": tab});
        let then = Then::Close {
            row,
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
                    Ok(snapshot) if snapshot.is_object() => {
                        let tab = tab_of(&snapshot).to_owned();
                        if self.status == "ready" {
                            self.upsert(snapshot);
                        }
                        if self.embedded {
                            self.notes.push(PreviewNote::Show(tab));
                        }
                    }
                    Ok(_) => {}
                }
            }
            Then::Show { generation, to } => {
                let snapshot = match result {
                    Err(error) => return self.notify("Could not open the page", error),
                    Ok(snapshot) => snapshot,
                };
                // Shown while its thread is, though the list was read again
                // meanwhile.
                if to.environment != self.environment
                    || to.thread != self.thread
                    || !snapshot.is_object()
                {
                    return;
                }
                let tab = tab_of(&snapshot).to_owned();
                if generation == self.generation && self.status == "ready" {
                    self.upsert(snapshot);
                }
                // The panel stopped showing tabs while it was opened.
                if self.embedded {
                    self.notes.push(PreviewNote::Show(tab));
                }
            }
            Then::Report { id } => {
                let unheard = match result {
                    Ok(_) => Unheard::Heard,
                    Err(error) => self.unheard(&error),
                };
                self.effects.push(Effect::Heard { id, unheard });
            }
            Then::Resize { id } => {
                let error = result.err();
                if let Some(error) = &error {
                    self.notify("Unable to resize browser viewport", error.clone());
                }
                self.effects.push(Effect::Resized { id, error });
            }
            Then::Navigate {
                generation,
                url,
                to,
            } => {
                let snapshot = match result {
                    Err(error) => return self.notify("Could not open the page", error),
                    Ok(snapshot) => snapshot,
                };
                if generation == self.generation && snapshot.is_object() && self.status == "ready" {
                    self.upsert(snapshot.clone());
                }
                // Remembered as the user went there, though the page never
                // loads here (opened in the user's browser).
                if to.environment == self.environment && to.thread == self.thread {
                    self.newest_stamp = self.newest_stamp.max(stamp_of(&snapshot));
                    let at = self.loaded_at(&snapshot);
                    self.keep(|history, project| history.visit(project, &url, "", at));
                }
                // The thread it was asked for, though another may show by
                // now; embedded, the tab's own page loads it.
                if !self.embedded {
                    self.open_for(&url, &to);
                }
            }
            Then::ListFor { url, to } => match result {
                Err(error) => self.notify("Could not open the page", error),
                Ok(list) => {
                    let tabs = list
                        .get("sessions")
                        .and_then(Json::as_array)
                        .map_or(&[][..], Vec::as_slice);
                    let named = self.port_named(&url, tabs);
                    self.open_through_tab(&url, to, named);
                }
            },
            Then::OpenFor {
                generation,
                url,
                to,
            } => {
                let snapshot = match result {
                    Err(error) => return self.notify("Could not open the page", error),
                    Ok(snapshot) => snapshot,
                };
                // A row only for the thread shown: the list this follows may
                // have come after the user went to another.
                if generation == self.generation
                    && to.environment == self.environment
                    && to.thread == self.thread
                    && snapshot.is_object()
                    && self.status == "ready"
                {
                    self.upsert(snapshot);
                }
                self.open_for(&url, &to);
            }
            Then::Forward { url, port } => match result {
                Err(error) => self.notify("Could not open the page", error),
                Ok(forward) => {
                    let port = forward
                        .get("port")
                        .and_then(Json::as_u64)
                        .and_then(|p| u16::try_from(p).ok())
                        .unwrap_or(port);
                    self.effects.push(Effect::Open(forwarded(&url, port)));
                }
            },
            Then::Close { row, tab } => {
                // Another thread, opened since, forgot what it was closing,
                // or the MC closed it anyway.
                let Some(snapshot) = self.closing.remove(&tab) else {
                    return;
                };
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
                    self.notes.push(PreviewNote::Tab(tab));
                }
                self.notify("Could not close the browser tab", error);
            }
        }
    }

    /// Why the MC did not take a report. Only "not connected" (no socket)
    /// proves it never had it. A connection that went with it written, a
    /// cluster member that could not be reached and a timeout can all come
    /// after the MC took it: the next word from the environment lists the
    /// tabs again.
    fn unheard(&mut self, error: &str) -> Unheard {
        if error == "not connected" {
            return Unheard::Unsent;
        }
        if error == "disconnected"
            || error.ends_with(" is not connected.")
            || error.starts_with("MC unavailable:")
            || error == "preview.reportStatus timed out"
        {
            self.unreached = true;
            return Unheard::Dropped;
        }
        Unheard::Refused
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
        // The tabs being closed that the MC still has, as the list and what
        // came after it say.
        let mut still_open = HashSet::new();
        let mut rows: Vec<Json> = list
            .get("sessions")
            .and_then(Json::as_array)
            .into_iter()
            .flatten()
            .filter(|s| match self.closing.get_mut(tab_of(s)) {
                Some(closing) => {
                    closing.clone_from(s);
                    still_open.insert(tab_of(s).to_owned());
                    false
                }
                None => true,
            })
            .cloned()
            .collect();
        text(&list, "serverEpoch").clone_into(&mut self.epoch);
        self.revision = revision_of(&list);
        self.last_event.clear();
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
            if revision <= self.revision {
                continue;
            }
            self.revision = revision;
            if self.follow_closing(&event) {
                still_open.insert(tab.to_owned());
                continue;
            }
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
        // One the MC no longer has (closed, or gone with a restart) is not
        // brought back by a close that then fails.
        self.closing.retain(|tab, _| still_open.contains(tab));
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
            let mut touched: Vec<String> = Vec::new();
            for row in self.rows.iter().chain(&rows) {
                let tab = tab_of(row);
                if !touched.iter().any(|t| t == tab) {
                    touched.push(tab.to_owned());
                }
            }
            self.rows = rows;
            if counted {
                self.notes.push(PreviewNote::Count);
            }
            self.notes.extend(touched.into_iter().map(PreviewNote::Tab));
        }
        self.set_status("ready", "");
        let rows = self.rows.clone();
        self.remember(&rows, false);
        self.notes.push(PreviewNote::Listed);
        if restarted {
            self.reload();
        }
    }

    /// A `preview` frame's event.
    pub fn on_event(&mut self, event: &Json) {
        if text(event, "threadId") != self.thread {
            return;
        }
        // Heard from an environment that was out of reach: what was missed
        // is listed.
        if std::mem::take(&mut self.unreached) {
            self.reload();
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
        if self.follow_closing(event) {
            return;
        }
        let tab = tab_of(event).to_owned();
        let row = self.row_of(&tab);
        let current = row.map(|row| &self.rows[row]);
        let next = after(event, current);
        let opened = next.is_some() && row.is_none() && text(event, "type") == "opened";
        match next {
            Some(next) => {
                let loaded = current.is_none_or(|before| loaded_url(before) != loaded_url(&next));
                self.last_event
                    .insert(tab.clone(), text(event, "type").to_owned());
                self.upsert(next.clone());
                self.remember(&[next], loaded);
            }
            None => {
                self.last_event.remove(&tab);
                self.remove(&tab);
            }
        }
        // A tab someone opened just now (an agent, another window), not one
        // listed.
        if self.embedded && opened {
            self.notes.push(PreviewNote::Show(tab));
        }
    }

    /// Keeps a tab being closed as `event` leaves it; whether it was one.
    fn follow_closing(&mut self, event: &Json) -> bool {
        let tab = tab_of(event);
        let Some(closing) = self.closing.get(tab) else {
            return false;
        };
        match after(event, Some(closing)) {
            Some(next) => {
                self.closing.insert(tab.to_owned(), next);
            }
            None => {
                self.closing.remove(tab);
            }
        }
        true
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
            self.notes.push(PreviewNote::Tab(tab));
            return;
        }
        self.rows.push(snapshot);
        self.changes.push(RowChange::Inserted {
            first: self.rows.len() - 1,
            keys: vec![key_of(&tab)],
        });
        self.notes.push(PreviewNote::Count);
        self.notes.push(PreviewNote::Tab(tab));
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
        self.notes.push(PreviewNote::Tab(tab.to_owned()));
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
/// The device's history as it keeps it ([`PreviewHistory::to_json`]): read,
/// and written.
pub type ReadHistory = Rc<dyn Fn(&Engine) -> Option<Json>>;
pub type WriteHistory = Rc<dyn Fn(&Engine, &Json)>;
/// Whether the MC the shell is connected to runs on this machine.
pub type Here = Rc<dyn Fn(&Engine) -> bool>;
/// How the MC took a page's report.
pub type OnHeard = Box<dyn FnOnce(&Engine, Unheard)>;
/// The MC's answer to a resize: why it refused.
pub type OnResized = Box<dyn FnOnce(&Engine, Option<String>)>;

struct Inner {
    rows: Rc<ListRows<Previews>>,
    mc: Rc<dyn Mc>,
    notify: Notify,
    open: Open,
    history: RefCell<Option<(ReadHistory, WriteHistory)>>,
    /// What the store last held, as read or written: it is parsed again
    /// only when that changes.
    kept: RefCell<Option<Json>>,
    /// Without one every MC counts as here.
    here: RefCell<Option<Here>>,
    servers: RefCell<Option<SubId>>,
    events: RefCell<Option<SubId>>,
    next_call: std::cell::Cell<u64>,
    heard: RefCell<HashMap<u64, OnHeard>>,
    resized: RefCell<HashMap<u64, OnResized>>,
}

impl Drop for Inner {
    fn drop(&mut self) {
        for sub in [self.servers.get_mut().take(), self.events.get_mut().take()]
            .into_iter()
            .flatten()
        {
            self.mc.unsubscribe(sub);
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

/// A thread's browser tabs: the Previews tab, and embedded, the browser
/// tabs' pages.
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
    /// What an empty tab offers: [{url, label, kind, title, detail}].
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
            history: RefCell::new(None),
            kept: RefCell::new(None),
            here: RefCell::new(None),
            servers: RefCell::new(None),
            events: RefCell::new(None),
            next_call: std::cell::Cell::new(0),
            heard: RefCell::new(HashMap::new()),
            resized: RefCell::new(HashMap::new()),
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

    /// Where the pages this device's tabs visited are kept: the right panel
    /// passes the device's previewHistory.
    pub fn set_history(
        engine: &Engine,
        obj: ObjectId,
        read: impl Fn(&Engine) -> Option<Json> + 'static,
        write: impl Fn(&Engine, &Json) + 'static,
    ) {
        if let Some(inner) = inner_of(engine, obj) {
            *inner.history.borrow_mut() = Some((Rc::new(read), Rc::new(write)));
            *inner.kept.borrow_mut() = None;
            ThreadPreviews::update(engine, obj, |_| ());
        }
    }

    /// Only a connected MC on this machine forwards to this machine's
    /// loopback: the right panel passes whether it runs here.
    pub fn set_connected_here(
        engine: &Engine,
        obj: ObjectId,
        here: impl Fn(&Engine) -> bool + 'static,
    ) {
        if let Some(inner) = inner_of(engine, obj) {
            *inner.here.borrow_mut() = Some(Rc::new(here));
        }
    }

    /// [`Previews::report`]; `unheard` runs with how the MC took it. False
    /// (and it never runs) when no call was made.
    pub fn report(
        engine: &Engine,
        obj: ObjectId,
        tab: &str,
        nav: Json,
        back: bool,
        forward: bool,
        unheard: impl FnOnce(&Engine, Unheard) + 'static,
    ) -> bool {
        let Some(inner) = inner_of(engine, obj) else {
            return false;
        };
        let id = call_id(&inner);
        inner.heard.borrow_mut().insert(id, Box::new(unheard));
        let made = ThreadPreviews::update(engine, obj, |p| p.report(tab, nav, back, forward, id));
        if made != Some(true) {
            inner.heard.borrow_mut().remove(&id);
        }
        made == Some(true)
    }

    /// [`Previews::resize_tab`]; `done` runs once the MC answers, with why
    /// it refused.
    pub fn resize_tab(
        engine: &Engine,
        obj: ObjectId,
        tab: &str,
        viewport: Json,
        done: impl FnOnce(&Engine, Option<String>) + 'static,
    ) {
        let Some(inner) = inner_of(engine, obj) else {
            return done(engine, Some("no such tab".to_owned()));
        };
        let id = call_id(&inner);
        inner.resized.borrow_mut().insert(id, Box::new(done));
        ThreadPreviews::update(engine, obj, |p| p.resize_tab(tab, viewport, id));
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
        let read = inner
            .history
            .borrow()
            .as_ref()
            .map(|(read, _)| read.clone());
        // Another window may have kept a visit since.
        let history = read.map(|read| read(engine).unwrap_or(Json::Null));
        let parsed = match &history {
            Some(json) if inner.kept.borrow().as_ref() != Some(json) => {
                *inner.kept.borrow_mut() = Some(json.clone());
                Some(Some(PreviewHistory::from_json(Some(json))))
            }
            Some(_) => None,
            None => Some(None),
        };
        let connected = inner.mc.environment();
        let here = inner.here.borrow().clone();
        let here = here.is_none_or(|here| here(engine));
        let now = crate::controllers::sidebar::now_ms(engine);
        let (result, notes, effects) = inner.rows.update(engine, |p| {
            if let Some(history) = parsed {
                p.set_history(history);
            }
            p.set_connection(&connected, here);
            p.set_now(now);
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

fn call_id(inner: &Inner) -> u64 {
    let id = inner.next_call.get() + 1;
    inner.next_call.set(id);
    id
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
            _ => Ok(()),
        });
    }
    warn(engine, result);
    if notes.contains(&PreviewNote::Suggestions) {
        tell_suggestions(engine, obj, &inner.rows);
    }
    // The signals last: what they tell of is in place.
    let cx = Cx::new(engine, obj);
    for note in notes {
        let emitted = match note {
            PreviewNote::Tab(tab) => ThreadPreviews::emit_tab_changed(&cx, Atom::new(tab)),
            PreviewNote::Listed => ThreadPreviews::emit_listed(&cx),
            PreviewNote::Show(tab) => ThreadPreviews::emit_show_requested(&cx, Atom::new(tab)),
            _ => Ok(()),
        };
        warn(engine, emitted);
    }
}

fn run(engine: &Engine, obj: ObjectId, inner: &Inner, effect: Effect) {
    match effect {
        Effect::FollowServers(mc) => {
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
            *inner.servers.borrow_mut() = Some(servers);
        }
        Effect::UnfollowServers => {
            let servers = inner.servers.borrow_mut().take();
            if let Some(servers) = servers {
                inner.mc.unsubscribe(servers);
            }
        }
        Effect::Follow(mc) => {
            let events = inner.mc.subscribe(
                json!({"type": "preview", "mc": mc}),
                Box::new(move |engine, frame| {
                    let event = frame.get("event").cloned().unwrap_or(Json::Null);
                    ThreadPreviews::update(engine, obj, |p| p.on_event(&event));
                }),
                None,
            );
            *inner.events.borrow_mut() = Some(events);
        }
        Effect::Unfollow => {
            let events = inner.events.borrow_mut().take();
            if let Some(events) = events {
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
        Effect::KeepHistory(history) => {
            let write = inner.history.borrow().as_ref().map(|(_, w)| w.clone());
            if let Some(write) = write {
                write(engine, &history);
                *inner.kept.borrow_mut() = Some(history);
            }
        }
        Effect::Heard { id, unheard } => {
            let heard = inner.heard.borrow_mut().remove(&id);
            if let Some(heard) = heard {
                heard(engine, unheard);
            }
        }
        Effect::Resized { id, error } => {
            let resized = inner.resized.borrow_mut().remove(&id);
            if let Some(resized) = resized {
                resized(engine, error);
            }
        }
    }
}

#[qml_impl]
impl ThreadPreviews {
    /// The MC said something new of the tab, or it went.
    #[qml(signal)]
    fn tab_changed(tab_id: Atom);

    /// The MC listed the thread's tabs (on showing, a reload, a reconnect);
    /// the rows that changed said so first.
    #[qml(signal)]
    fn listed();

    /// Embedded: the tab is to be shown: the user asked (show, newTab,
    /// openAddress), or someone opened it just now (an agent, another
    /// window).
    #[qml(signal)]
    fn show_requested(tab_id: Atom);

    #[qml(invokable)]
    fn reload(cx: &Cx) {
        ThreadPreviews::update(cx.engine, cx.this, Previews::reload);
    }

    /// Opens the tab's page in the browser.
    #[qml(invokable)]
    fn open(cx: &Cx, tab_id: Atom) {
        ThreadPreviews::update(cx.engine, cx.this, |p| p.open(&tab_id));
    }

    /// Takes the page off the project's recent pages.
    #[qml(invokable)]
    fn forget(cx: &Cx, url: Atom) {
        ThreadPreviews::update(cx.engine, cx.this, |p| p.forget(&url));
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

    /// Opens `url` in the browser, for the thread: through the connected
    /// MC's forward when it is a dev server on the thread's machine, another
    /// MC's.
    #[qml(invokable)]
    fn open_address(cx: &Cx, url: Atom) {
        ThreadPreviews::update(cx.engine, cx.this, |p| p.open_address(&url));
    }

    /// Embedded: shows the tab in the panel (`showRequested`).
    #[qml(invokable)]
    fn show(cx: &Cx, tab_id: Atom) {
        ThreadPreviews::update(cx.engine, cx.this, |p| p.show(&tab_id));
    }
}

#[cfg(test)]
#[path = "previews_tests.rs"]
mod tests;
