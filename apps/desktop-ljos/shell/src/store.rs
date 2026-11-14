//! The MC's `shell` shape folded into rows, ported from desktop-qt's
//! ShellStore: every MC of the cluster, its environment descriptor, and its
//! live projects and threads. Each change (`shell.rows`, `shell.environment`,
//! `shell.mc`) is applied as it comes; a member that goes offline keeps its
//! rows, and one removed from the cluster takes them with it. A thread that
//! moved to another machine leaves a forwarding record (`movedTo`) on the one
//! it left: the thread is listed where it lives, and [`ShellStore::located`]
//! follows the record.
//!
//! The rows are kept in the [`LocalCache`] with the version the MC gave each
//! MC's (`epoch`, `rev`), so the next subscription, after a reconnect or a
//! restart, says what it holds (`have`) and is sent only the rows changed
//! since. Rows read from the cache show at once but are not the MC's word
//! yet: [`ShellStore::previewing`] holds and [`ShellStore::synchronized`]
//! stays false until its `shell` frame.
//!
//! [`ShellStore`] is the fold, without the engine. [`install`] puts one in
//! the engine, subscribed to the MC, and the rest of this module is how a
//! controller reaches it:
//!
//! ```ignore
//! store::on_changed(engine, |engine| refresh(engine));     // after each change
//! let rows = store::with(engine, |s| s.threads());          // read
//! ```

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, BTreeSet};
use std::rc::Rc;
use std::time::Duration;

use ljos::prelude::Engine;
use ljos::prelude::TimerId;
use serde_json::{Map, Value, json};

use crate::cache::{self, LocalCache};
use crate::mc::{Frame, Mc, SubId};
use crate::sidebar_model::{self as sidebar, Capabilities};

/// How long row changes wait for more before they go to the cache.
pub const FLUSH_DELAY_MS: u64 = 500;

pub type Row = Map<String, Value>;

/// The client a `shell` subscription came on: the shell's own, or the link
/// to a saved environment, named by that environment's id
/// (desktop-qt's ShellStore links).
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Client {
    Own,
    Link(String),
}

#[derive(Clone, Debug, Default, PartialEq)]
struct McRows {
    /// The client whose shell lists it; none for one read from the cache
    /// that no client has listed yet this run.
    link: Option<Client>,
    environment_id: String,
    capabilities: Row,
    environment: Row,
    online: bool,
    /// The cluster has stopped trying to reach it while it is down
    /// (`trying` false).
    given_up: bool,
    /// The version of its rows; no epoch when the MC gave none.
    epoch: String,
    rev: i64,
    threads: BTreeMap<String, Row>,
    projects: BTreeMap<String, Row>,
}

impl McRows {
    /// Its rows of `kind`, or nothing for kinds the shell does not fold.
    fn rows(&mut self, kind: &str) -> Option<&mut BTreeMap<String, Row>> {
        match kind {
            "thread" => Some(&mut self.threads),
            "project" => Some(&mut self.projects),
            _ => None,
        }
    }
}

/// What the cache has not been told of one MC.
#[derive(Clone, Debug, Default)]
struct Unsaved {
    reset: bool,
    put: BTreeMap<String, cache::ShellRow>,
    gone: BTreeSet<String>,
}

fn removed(row: &Row) -> bool {
    row.is_empty() || row.get("deletedAt").is_some_and(|v| !v.is_null())
}

fn thread_key(environment_id: &str, thread_id: &str) -> String {
    format!("{environment_id}:{thread_id}")
}

/// `environmentId:rest`, split; none without an environment.
fn split_key(key: &str) -> Option<(&str, &str)> {
    key.split_once(':').filter(|(env, _)| !env.is_empty())
}

fn object(value: Option<&Value>) -> Row {
    value
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default()
}

fn text(value: Option<&Value>) -> String {
    value.and_then(Value::as_str).unwrap_or("").to_owned()
}

/// The origin the cache files rows under: scheme, host and port, without
/// credentials, path, query or fragment.
pub fn origin_key(origin: &str) -> String {
    match url::Url::parse(origin) {
        Ok(url) if url.has_host() => {
            let mut key = format!("{}://{}", url.scheme(), url.host_str().unwrap_or(""));
            if let Some(port) = url.port() {
                key.push_str(&format!(":{port}"));
            }
            key
        }
        _ => origin.to_owned(),
    }
}

/// What a call changed, for whoever is told.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Changes {
    /// The rows, an environment or the state (synchronized, previewing,
    /// problem) changed.
    pub changed: bool,
    /// The rows held were another MC's: nothing kept of the first is this
    /// one's to show.
    pub origin_changed: bool,
}

impl Changes {
    fn changed(changed: bool) -> Changes {
        Changes {
            changed,
            origin_changed: false,
        }
    }
}

#[derive(Default)]
pub struct ShellStore {
    mcs: BTreeMap<String, McRows>,
    /// The saved environments linked to ([`ShellStore::add_link`]).
    links: BTreeSet<String>,
    cache: Option<Rc<LocalCache>>,
    origin: String,
    unsaved: BTreeMap<String, Unsaved>,
    /// Changes wait for a flush: desktop-qt's running flush timer.
    flush_due: bool,
    previewing: bool,
    synchronized: bool,
    snapshots: u64,
    /// News of the cluster's members, counted: see [`ShellStore::roster`].
    roster: u64,
    problem: String,
    /// Which read of the cache's kept rows counts: an earlier one comes back
    /// for a store that has since moved on.
    asked: u64,
    /// What the cache answered the latest read with, until [`ShellStore::take_kept`].
    kept: Rc<RefCell<Option<(u64, cache::Shell)>>>,
}

impl ShellStore {
    /// Rows kept in `cache` between runs; without one nothing is.
    pub fn new(cache: Option<Rc<LocalCache>>) -> ShellStore {
        let mut store = ShellStore::default();
        store.cache = cache;
        store
    }

    pub fn cache(&self) -> Option<&Rc<LocalCache>> {
        self.cache.as_ref()
    }

    /// Before the shell knows where its MC is: asks the cache for the rows
    /// kept for the MC it was last opened at, held by
    /// [`ShellStore::take_kept`].
    pub fn show_kept(&mut self) {
        if let Some(cache) = self.cache.clone().filter(|_| self.origin.is_empty()) {
            self.ask_kept(&cache, "");
        }
    }

    /// The shell is being opened at `origin`: what was held goes, and the
    /// rows last kept for it are asked for, held by
    /// [`ShellStore::take_kept`] until its MC answers
    /// ([`ShellStore::previewing`]). Another origin's rows go.
    pub fn open(&mut self, origin: &str) -> Changes {
        let key = origin_key(origin);
        // The MC whose rows are held, kept or its own, stays as it is.
        if key == self.origin {
            return Changes::default();
        }
        self.flush();
        let another = !self.origin.is_empty();
        let changed = self.hold(cache::Shell::default(), key.clone());
        if let Some(cache) = self.cache.clone() {
            self.ask_kept(&cache, &key);
        }
        Changes {
            changed,
            origin_changed: another,
        }
    }

    fn ask_kept(&mut self, cache: &LocalCache, origin: &str) {
        self.asked += 1;
        let (asked, inbox) = (self.asked, self.kept.clone());
        cache.shell(origin, move |shell| {
            *inbox.borrow_mut() = Some((asked, shell))
        });
    }

    /// Holds the rows the cache answered [`ShellStore::open`] or
    /// [`ShellStore::show_kept`] with, once it has (after
    /// [`LocalCache::deliver`]), unless the store has moved on since: opened
    /// elsewhere, cleared, or its MC answered first.
    pub fn take_kept(&mut self) -> Changes {
        let Some((asked, kept)) = self.kept.borrow_mut().take() else {
            return Changes::default();
        };
        if asked != self.asked {
            return Changes::default();
        }
        if self.synchronized {
            // Its MC's rows stand, and it never said a machine that left
            // while the shell was away is gone: only this read shows it.
            for mc in &kept.mcs {
                if !self.mcs.contains_key(&mc.mc) {
                    self.unsaved(&mc.mc);
                }
            }
            self.flush();
            return Changes::default();
        }
        if !self.mcs.is_empty() {
            return Changes::default();
        }
        let origin = if self.origin.is_empty() {
            kept.origin.clone()
        } else {
            self.origin.clone()
        };
        if origin.is_empty() {
            return Changes::default();
        }
        Changes::changed(self.hold(kept, origin))
    }

    /// Takes the rows the cache kept for `origin` in place of the ones held.
    fn hold(&mut self, kept: cache::Shell, origin: String) -> bool {
        self.origin = origin;
        let held = !self.mcs.is_empty();
        self.mcs.clear();
        self.synchronized = false;
        self.previewing = false;
        for mc in kept.mcs {
            self.set_environment(&mc.mc, mc.environment);
            let entry = self.mcs.entry(mc.mc).or_default();
            entry.epoch = mc.epoch;
            entry.rev = mc.rev;
            for row in mc.rows {
                if let Some(rows) = entry.rows(&row.kind) {
                    rows.insert(row.id, row.fields);
                }
            }
            self.previewing = true;
        }
        // Read, not changed: nothing of it is owed to the cache.
        self.unsaved.clear();
        self.flush_due = false;
        held || self.previewing
    }

    /// Whether the rows hold `mc`'s version (`epoch`, `rev`): true too for
    /// an MC the store does not follow, or one since reset to another epoch.
    pub fn reached(&self, mc: &str, epoch: &str, rev: i64) -> bool {
        self.mcs
            .get(mc)
            .is_none_or(|rows| rows.epoch != epoch || rows.rev >= rev)
    }

    /// Whether the rows held came from the cache and no MC has confirmed them.
    pub fn previewing(&self) -> bool {
        self.previewing
    }

    /// Whether the MC has said what the cluster holds: only then is a row
    /// that is missing a row that is gone.
    pub fn synchronized(&self) -> bool {
        self.synchronized
    }

    /// How many `shell` frames have landed: one per (re)subscription the MC
    /// answered.
    pub fn snapshots(&self) -> u64 {
        self.snapshots
    }

    /// Why the MC turned the shell subscription down (its `error` frame);
    /// empty once a snapshot lands. The rows it had stay as they were.
    pub fn problem(&self) -> &str {
        &self.problem
    }

    /// The origin whose rows are held; empty before one is.
    pub fn origin(&self) -> &str {
        &self.origin
    }

    /// What the shell's own `shell` subscription carries as `have`: each
    /// MC's version as held.
    pub fn have(&self) -> Value {
        self.have_for(&Client::Own)
    }

    /// What `client`'s `shell` subscription carries as `have`: the versions
    /// of the MCs it speaks for.
    pub fn have_for(&self, client: &Client) -> Value {
        Value::Object(
            self.mcs
                .iter()
                .filter(|(_, mc)| !mc.epoch.is_empty() && self.answers_for(client, mc))
                .map(|(name, mc)| (name.clone(), json!([mc.epoch, mc.rev])))
                .collect(),
        )
    }

    /// Whether row changes wait for [`ShellStore::flush`].
    pub fn flush_due(&self) -> bool {
        self.flush_due
    }

    fn unsaved(&mut self, mc: &str) -> &mut Unsaved {
        self.flush_due = true;
        self.unsaved.entry(mc.to_owned()).or_default()
    }

    /// Hands the cache the row changes it has not been given.
    pub fn flush(&mut self) {
        self.flush_due = false;
        let unsaved = std::mem::take(&mut self.unsaved);
        let Some(cache) = self.cache.as_ref() else {
            return;
        };
        if self.origin.is_empty() || unsaved.is_empty() {
            return;
        }
        let updates = unsaved
            .into_iter()
            .map(|(name, change)| match self.mcs.get(&name) {
                None => cache::ShellMcUpdate {
                    mc: name,
                    removed: true,
                    ..cache::ShellMcUpdate::default()
                },
                Some(mc) => cache::ShellMcUpdate {
                    mc: name,
                    removed: false,
                    reset: change.reset,
                    epoch: mc.epoch.clone(),
                    rev: mc.rev,
                    environment: mc.environment.clone(),
                    put: change.put.into_values().collect(),
                    gone: change.gone.into_iter().collect(),
                },
            })
            .collect();
        cache.store_shell(&self.origin, updates);
    }

    /// The shell left its MC: every machine and row goes, here and in the
    /// cache. It reads as synchronized, an empty cluster. `done` hears false
    /// when what the cache kept could not be deleted.
    pub fn clear(&mut self, done: impl FnOnce(bool) + 'static) {
        self.forget();
        match &self.cache {
            Some(cache) => cache.clear(done),
            None => done(true),
        }
    }

    /// [`ShellStore::clear`] without the cache.
    fn forget(&mut self) {
        // A read of kept rows in flight is for what is gone.
        self.asked += 1;
        // Nothing of it is owed to the cache any more.
        self.flush_due = false;
        self.unsaved.clear();
        self.origin.clear();
        self.mcs.clear();
        self.problem.clear();
        self.previewing = false;
        self.synchronized = true;
    }

    /// Starts holding what the saved environment `environment_id`'s own
    /// link lists; whether it was not linked already.
    pub fn add_link(&mut self, environment_id: &str) -> bool {
        self.links.insert(environment_id.to_owned())
    }

    /// Stops holding what the link to `environment_id` lists: its MCs go
    /// when the environment is `forget`ten, else they stay, listed by no
    /// client, until one lists them again. Whether anything changed.
    pub fn remove_link(&mut self, environment_id: &str, forget: bool) -> bool {
        if !self.links.remove(environment_id) {
            return false;
        }
        let link = Client::Link(environment_id.to_owned());
        let names: Vec<String> = self
            .mcs
            .iter()
            .filter(|(_, mc)| {
                mc.link.as_ref() == Some(&link)
                    || (mc.link.is_none() && mc.environment_id == environment_id)
            })
            .map(|(name, _)| name.clone())
            .collect();
        let changed = forget && !names.is_empty();
        for name in names {
            if forget {
                self.remove_mc(&name);
            } else if let Some(mc) = self.mcs.get_mut(&name) {
                mc.link = None;
            }
        }
        changed
    }

    /// The saved environment whose link serves `environment_id`; none when
    /// the shell's own client does, or no client lists it yet and it is not
    /// linked.
    pub fn link_serving(&self, environment_id: &str) -> Option<String> {
        if let Some((_, mc)) = self.serving(environment_id) {
            return match &mc.link {
                Some(Client::Link(link)) => Some(link.clone()),
                _ => None,
            };
        }
        self.links.get(environment_id).cloned()
    }

    /// The saved environment whose link listed `mc`, or, for one no client
    /// has listed yet, the link of its environment ([`Self::answers_for`]);
    /// none for the shell's own client's.
    pub fn link_of(&self, mc: &str) -> Option<String> {
        let mc = self.mcs.get(mc)?;
        match &mc.link {
            Some(Client::Link(link)) => Some(link.clone()),
            Some(Client::Own) => None,
            None => self.links.get(&mc.environment_id).cloned(),
        }
    }

    /// The saved environments linked to.
    pub fn links(&self) -> &BTreeSet<String> {
        &self.links
    }

    /// Whether `client`'s snapshot speaks for `mc`: the client that listed
    /// it, or, for one kept from the last run, the link of its environment,
    /// and the shell's own client for any no link serves.
    fn answers_for(&self, client: &Client, mc: &McRows) -> bool {
        match &mc.link {
            Some(link) => link == client,
            None if self.links.contains(&mc.environment_id) => {
                *client == Client::Link(mc.environment_id.clone())
            }
            None => *client == Client::Own,
        }
    }

    /// Applies one frame of the shell's own `shell` subscription; whether it
    /// changed anything.
    pub fn apply(&mut self, frame: &Frame) -> bool {
        self.apply_from(frame, &Client::Own)
    }

    /// Applies one frame of `client`'s `shell` subscription; whether it
    /// changed anything. A frame about an MC claims it for that client, and
    /// a snapshot removes only the MCs that client speaks for.
    pub fn apply_from(&mut self, frame: &Frame, client: &Client) -> bool {
        let kind = frame.get("t").and_then(Value::as_str).unwrap_or("");
        if !matches!(
            kind,
            "shell" | "error" | "shell.environment" | "shell.mc" | "shell.rows"
        ) {
            return false;
        }
        // A saved environment's own refusal is that link's status
        // (SavedEnvironments), not the shell's problem.
        if kind == "error" && *client != Client::Own {
            return false;
        }
        if let Some(mc) = frame.get("mc").and_then(Value::as_str)
            && !mc.is_empty()
            && frame.get("removed").and_then(Value::as_bool) != Some(true)
        {
            self.mcs.entry(mc.to_owned()).or_default().link = Some(client.clone());
        }
        match kind {
            "shell" => {
                // The cluster's members, and the rows this client lacks of
                // each: all of them for an MC marked `reset` (or sent by an
                // MC that keeps no versions), else the ones changed since the
                // `have` it was sent.
                let mut listed = BTreeSet::new();
                let mut replaced = BTreeSet::new();
                let mcs = frame.get("mcs").and_then(Value::as_array);
                for mc in mcs.into_iter().flatten() {
                    let name = text(mc.get("mc"));
                    listed.insert(name.clone());
                    self.mcs.entry(name.clone()).or_default().link = Some(client.clone());
                    if mc.get("reset").and_then(Value::as_bool).unwrap_or(true) {
                        self.reset_rows(&name, &mut replaced);
                    }
                    self.set_environment(&name, object(mc.get("environment")));
                    let entry = self.mcs.entry(name.clone()).or_default();
                    entry.online = mc.get("online").and_then(Value::as_bool).unwrap_or(false);
                    entry.given_up = mc.get("trying").and_then(Value::as_bool) == Some(false);
                    self.set_version(&name, mc.get("epoch"), mc.get("rev"));
                }
                // Only the MCs this client speaks for: another link's are its own.
                let gone: Vec<String> = self
                    .mcs
                    .iter()
                    .filter(|(name, mc)| !listed.contains(*name) && self.answers_for(client, mc))
                    .map(|(name, _)| name.clone())
                    .collect();
                for name in gone {
                    self.remove_mc(&name);
                }
                let rows = frame.get("rows").and_then(Value::as_array);
                for row in rows.into_iter().flatten() {
                    let at = |i: usize| row.get(i);
                    self.put_row(&text(at(0)), &text(at(1)), &text(at(2)), object(at(3)));
                }
                self.forget_threads(&replaced);
                // The shell's own MC is the one whose word makes the rows live.
                if *client == Client::Own {
                    self.synchronized = true;
                    self.previewing = false;
                    self.snapshots += 1;
                    self.problem.clear();
                }
                self.flush();
            }
            "error" => {
                self.problem = frame
                    .get("reason")
                    .and_then(Value::as_str)
                    .unwrap_or("The MC did not send its projects and threads.")
                    .to_owned();
            }
            "shell.environment" => {
                self.set_environment(&text(frame.get("mc")), object(frame.get("environment")));
            }
            "shell.mc" => {
                let mc = text(frame.get("mc"));
                self.roster += 1;
                // A machine removed from the cluster takes its rows with it;
                // an offline one keeps them.
                if frame.get("removed").and_then(Value::as_bool) == Some(true) {
                    self.remove_mc(&mc);
                } else {
                    let entry = self.mcs.entry(mc).or_default();
                    entry.online = frame
                        .get("online")
                        .and_then(Value::as_bool)
                        .unwrap_or(false);
                    entry.given_up = frame.get("trying").and_then(Value::as_bool) == Some(false);
                }
            }
            "shell.rows" => {
                let mc = text(frame.get("mc"));
                let mut replaced = BTreeSet::new();
                if frame.get("reset").and_then(Value::as_bool) == Some(true) {
                    self.reset_rows(&mc, &mut replaced);
                }
                // Rows as `shell.rows` carries them: each [id, kind, fields].
                let rows = frame.get("rows").and_then(Value::as_array);
                for row in rows.into_iter().flatten() {
                    let at = |i: usize| row.get(i);
                    self.put_row(&mc, &text(at(0)), &text(at(1)), object(at(2)));
                }
                // They bring the MC's rows to this version; a frame without
                // one leaves none to resume from.
                self.set_version(&mc, frame.get("epoch"), frame.get("rev"));
                self.forget_threads(&replaced);
            }
            _ => return false,
        }
        true
    }

    fn set_environment(&mut self, mc: &str, environment: Row) {
        let entry = self.mcs.entry(mc.to_owned()).or_default();
        entry.environment_id = text(environment.get("environmentId"));
        entry.capabilities = object(environment.get("capabilities"));
        entry.environment = environment;
        self.roster += 1;
        self.unsaved(mc);
    }

    /// The MC's rows as of `epoch` and `rev` (a frame's); none when it gave
    /// no version.
    fn set_version(&mut self, mc: &str, epoch: Option<&Value>, rev: Option<&Value>) {
        let entry = self.mcs.entry(mc.to_owned()).or_default();
        let epoch = epoch.and_then(Value::as_str).filter(|e| !e.is_empty());
        let rev = rev.and_then(Value::as_f64);
        match epoch.zip(rev) {
            Some((epoch, rev)) => {
                entry.epoch = epoch.to_owned();
                entry.rev = rev as i64;
            }
            None => {
                entry.epoch.clear();
                entry.rev = 0;
            }
        }
        self.unsaved(mc);
    }

    fn put_row(&mut self, mc: &str, id: &str, kind: &str, fields: Row) {
        let entry = self.mcs.entry(mc.to_owned()).or_default();
        let environment_id = entry.environment_id.clone();
        let Some(kept) = entry.rows(kind) else {
            return;
        };
        if removed(&fields) {
            kept.remove(id);
            let change = self.unsaved(mc);
            change.put.remove(id);
            if !change.reset {
                change.gone.insert(id.to_owned());
            }
            // A deleted thread is not coming back to be read.
            if kind == "thread"
                && !environment_id.is_empty()
                && let Some(cache) = &self.cache
            {
                cache.forget_thread(&thread_key(&environment_id, id));
            }
        } else {
            kept.insert(id.to_owned(), fields.clone());
            let change = self.unsaved(mc);
            change.gone.remove(id);
            change.put.insert(
                id.to_owned(),
                cache::ShellRow {
                    id: id.to_owned(),
                    kind: kind.to_owned(),
                    fields,
                },
            );
        }
    }

    /// Drops the MC's rows, which the frame being applied replaces; the keys
    /// of its threads go to `threads`.
    fn reset_rows(&mut self, mc: &str, threads: &mut BTreeSet<String>) {
        let entry = self.mcs.entry(mc.to_owned()).or_default();
        if !entry.environment_id.is_empty() {
            for id in entry.threads.keys() {
                threads.insert(thread_key(&entry.environment_id, id));
            }
        }
        entry.threads.clear();
        entry.projects.clear();
        let change = self.unsaved(mc);
        *change = Unsaved {
            reset: true,
            ..Unsaved::default()
        };
    }

    fn remove_mc(&mut self, mc: &str) {
        let environment_id = self
            .mcs
            .remove(mc)
            .map(|m| m.environment_id)
            .unwrap_or_default();
        *self.unsaved(mc) = Unsaved {
            reset: true,
            ..Unsaved::default()
        };
        // Its threads go with it, unless another MC serves the environment
        // now (an MC's name changes when it joins a cluster).
        if !environment_id.is_empty()
            && !self.serves_environment(&environment_id)
            && let Some(cache) = &self.cache
        {
            cache.forget_environment(&environment_id);
        }
    }

    /// Forgets the cached copies of `threads` (keys) that are no longer listed.
    fn forget_threads(&self, threads: &BTreeSet<String>) {
        let Some(cache) = &self.cache else {
            return;
        };
        for key in threads {
            if self.thread_row(key).is_none() {
                cache.forget_thread(key);
            }
        }
    }

    /// Whether `row` is the thread itself: not the forwarding record of a
    /// move, nor the copy its old machine still holds once the new one has it.
    fn lives(&self, row: &Row) -> bool {
        if row.get("movedTo").is_some_and(Value::is_object) {
            return false;
        }
        let moving = object(row.get("moving"));
        if moving.is_empty() {
            return true;
        }
        let destination = text(moving.get("environmentId"));
        let id = text(row.get("id"));
        match self
            .mcs
            .values()
            .find(|mc| mc.environment_id == destination)
        {
            Some(mc) => mc
                .threads
                .get(&id)
                .is_none_or(|arrived| arrived.get("movedTo").is_some_and(Value::is_object)),
            None => true,
        }
    }

    fn serving(&self, environment_id: &str) -> Option<(&String, &McRows)> {
        self.mcs
            .iter()
            .find(|(_, mc)| mc.environment_id == environment_id)
    }

    /// Every live thread of the cluster.
    pub fn threads(&self) -> Vec<sidebar::Thread> {
        let mut result = Vec::new();
        for mc in self.mcs.values() {
            // An MC whose environment is not known yet has no key for its threads.
            if mc.environment_id.is_empty() {
                continue;
            }
            for row in mc.threads.values() {
                if self.lives(row) {
                    result.push(sidebar::thread_from_row(&mc.environment_id, row));
                }
            }
        }
        result
    }

    /// Every project of the cluster, by creation.
    pub fn projects(&self) -> Vec<sidebar::Project> {
        let mut result: Vec<sidebar::Project> = self
            .mcs
            .values()
            .filter(|mc| !mc.environment_id.is_empty())
            .flat_map(|mc| {
                mc.projects
                    .values()
                    .map(|row| sidebar::project_from_row(&mc.environment_id, row))
            })
            .collect();
        result.sort_by(|l, r| {
            l.created_at
                .cmp(&r.created_at)
                .then_with(|| l.key().cmp(&r.key()))
        });
        result
    }

    /// The project at `environmentId:projectId`.
    pub fn project(&self, key: &str) -> Option<sidebar::Project> {
        let (environment_id, id) = split_key(key)?;
        let (_, mc) = self.serving(environment_id)?;
        mc.projects
            .get(id)
            .map(|row| sidebar::project_from_row(environment_id, row))
    }

    /// The live thread at `environmentId:threadId`.
    pub fn thread(&self, key: &str) -> Option<sidebar::Thread> {
        let (environment_id, id) = split_key(key)?;
        let (_, mc) = self.serving(environment_id)?;
        mc.threads
            .get(id)
            .filter(|row| self.lives(row))
            .map(|row| sidebar::thread_from_row(environment_id, row))
    }

    /// The raw row, none when the cluster has none by that key. It may be
    /// the forwarding record of a move.
    pub fn thread_row(&self, key: &str) -> Option<&Row> {
        let (environment_id, id) = split_key(key)?;
        self.serving(environment_id)?.1.threads.get(id)
    }

    /// The key the thread at `key` lives under now: another machine's once
    /// it moved there, `key` itself otherwise. Keys kept from before a move
    /// (a saved route, a notification, a draft) resolve through this.
    pub fn located(&self, key: &str) -> String {
        let Some(row) = self.thread_row(key).filter(|row| !self.lives(row)) else {
            return key.to_owned();
        };
        let id = key.split_once(':').map_or(key, |(_, id)| id);
        for mc in self.mcs.values() {
            if mc.environment_id.is_empty() {
                continue;
            }
            if mc.threads.get(id).is_some_and(|found| self.lives(found)) {
                return thread_key(&mc.environment_id, id);
            }
        }
        // Its new machine's rows have not arrived yet: where the record points.
        let moved_to = text(object(row.get("movedTo")).get("environmentId"));
        if moved_to.is_empty() {
            key.to_owned()
        } else {
            thread_key(&moved_to, id)
        }
    }

    pub fn project_row(&self, environment_id: &str, project_id: &str) -> Option<&Row> {
        self.serving(environment_id)?.1.projects.get(project_id)
    }

    pub fn project_rows(&self, environment_id: &str) -> Vec<&Row> {
        self.serving(environment_id)
            .map(|(_, mc)| mc.projects.values().collect())
            .unwrap_or_default()
    }

    /// Counts the news of the cluster's members: a descriptor, or a member
    /// going online, offline or away. What the MC refused for an environment
    /// it did not know (McPlugin) is asked again once this moves.
    pub fn roster(&self) -> u64 {
        self.roster
    }

    /// The environments the cluster serves.
    pub fn environments(&self) -> Vec<String> {
        self.mcs
            .values()
            .filter(|mc| !mc.environment_id.is_empty())
            .map(|mc| mc.environment_id.clone())
            .collect()
    }

    /// The environment's descriptor; empty when none is served.
    pub fn environment(&self, environment_id: &str) -> Row {
        self.serving(environment_id)
            .map(|(_, mc)| mc.environment.clone())
            .unwrap_or_default()
    }

    /// The cluster MC serving `environment_id`, for MC-addressed shapes;
    /// empty when none does.
    pub fn mc_serving(&self, environment_id: &str) -> String {
        self.serving(environment_id)
            .map(|(name, _)| name.clone())
            .unwrap_or_default()
    }

    /// The environment the cluster's `mc` serves, empty until its descriptor
    /// arrives.
    pub fn environment_of(&self, mc: &str) -> String {
        self.mcs
            .get(mc)
            .map(|m| m.environment_id.clone())
            .unwrap_or_default()
    }

    pub fn capabilities(&self, environment_id: &str) -> Capabilities {
        self.serving(environment_id)
            .map(|(_, mc)| Capabilities::from_descriptor(&mc.environment))
            .unwrap_or_default()
    }

    /// Whether the environment's descriptor turns `capability` on
    /// (pullRequests, threadPullRequests, ...).
    pub fn supports(&self, environment_id: &str, capability: &str) -> bool {
        self.serving(environment_id).is_some_and(|(_, mc)| {
            mc.capabilities
                .get(capability)
                .and_then(Value::as_bool)
                .unwrap_or(false)
        })
    }

    /// Whether an MC of the cluster serves this environment.
    pub fn serves_environment(&self, environment_id: &str) -> bool {
        self.serving(environment_id).is_some()
    }

    /// Whether the MC whose row lists this thread is online; false while none
    /// lists it.
    pub fn thread_online(&self, thread_key: &str) -> bool {
        let Some((environment_id, id)) = split_key(thread_key) else {
            return false;
        };
        self.mcs
            .values()
            .find(|mc| mc.environment_id == environment_id && mc.threads.contains_key(id))
            .is_some_and(|mc| mc.online)
    }

    /// Whether an MC serving `environment_id` is online.
    pub fn environment_online(&self, environment_id: &str) -> bool {
        self.serving(environment_id)
            .is_some_and(|(_, mc)| mc.online)
    }

    /// Whether the cluster still tries to reach the environment's MC: online,
    /// or down and not given up on. True for one no MC serves.
    pub fn environment_trying(&self, environment_id: &str) -> bool {
        self.serving(environment_id)
            .is_none_or(|(_, mc)| mc.online || !mc.given_up)
    }
}

impl Drop for ShellStore {
    fn drop(&mut self) {
        self.flush();
    }
}

type Listener = Rc<dyn Fn(&Engine, Changes)>;

/// Work waiting for the store ([`when_installed`]).
type Waiting = Box<dyn FnOnce(&Engine)>;

/// The engine's store, its subscription and who is told of its changes.
#[derive(Default)]
struct Slot {
    store: RefCell<Option<Rc<RefCell<ShellStore>>>>,
    listeners: RefCell<Vec<Listener>>,
    subscription: Cell<Option<SubId>>,
    /// What waits for the store to be installed ([`when_installed`]).
    installed: RefCell<Vec<Waiting>>,
    /// The pending flush, desktop-qt's single-shot timer.
    flush: Cell<Option<TimerId>>,
    /// Each saved environment's link and its `shell` subscription.
    links: RefCell<BTreeMap<String, crate::mc::Held>>,
}

/// Puts a store over `cache` in the engine and subscribes it to `mc`'s
/// `shell` shape, which resumes from what the store holds. Once per engine.
pub fn install(engine: &Engine, mc: &Rc<dyn Mc>, cache: Option<Rc<LocalCache>>) {
    let slot = engine.extension::<Slot>();
    assert!(slot.store.borrow().is_none(), "the store is installed once");
    let store = Rc::new(RefCell::new(ShellStore::new(cache)));
    *slot.store.borrow_mut() = Some(store.clone());
    let weak = Rc::downgrade(&store);
    let resume = Box::new(move || {
        let have = weak
            .upgrade()
            .and_then(|s| s.try_borrow().ok().map(|s| s.have()))
            .unwrap_or_else(|| json!({}));
        let mut frame = Frame::new();
        frame.insert("have".into(), have);
        frame
    });
    let weak = Rc::downgrade(&store);
    let weak_mc = Rc::downgrade(mc);
    let id = mc.subscribe(
        json!({"type": "shell"}),
        Box::new(move |engine, frame| {
            let Some(store) = weak.upgrade() else {
                return;
            };
            let changed = store.borrow_mut().apply(frame);
            settle(engine, Changes::changed(changed));
            // What its snapshot lists is the shell's own again: what was
            // held on a link for it comes back ([`Mc::reroute`]).
            if frame.get("t").and_then(Value::as_str) == Some("shell")
                && let Some(own) = weak_mc.upgrade()
            {
                own.reroute();
            }
        }),
        Some(resume),
    );
    slot.subscription.set(Some(id));
    let waiting = std::mem::take(&mut *slot.installed.borrow_mut());
    for f in waiting {
        f(engine);
    }
}

/// Subscribes the store to the `shell` shape of `link`, the client of the
/// saved environment `environment_id`, beside the shell's own: what it lists
/// is held as that link's (desktop-qt's ShellStore::addLink). Once per link
/// until [`remove_link`]; nothing before the store is installed.
pub fn add_link(engine: &Engine, environment_id: &str, link: Rc<dyn Mc>) {
    let Some(store) = get(engine) else {
        return;
    };
    let slot = engine.extension::<Slot>();
    if slot.links.borrow().contains_key(environment_id) {
        return;
    }
    store.borrow_mut().add_link(environment_id);
    let client = Client::Link(environment_id.to_owned());
    let weak = Rc::downgrade(&store);
    let asking = client.clone();
    let resume = Box::new(move || {
        let have = weak
            .upgrade()
            .and_then(|s| s.try_borrow().ok().map(|s| s.have_for(&asking)))
            .unwrap_or_else(|| json!({}));
        let mut frame = Frame::new();
        frame.insert("have".into(), have);
        frame
    });
    let weak = Rc::downgrade(&store);
    let id = link.subscribe(
        json!({"type": "shell"}),
        Box::new(move |engine, frame| {
            let Some(store) = weak.upgrade() else {
                return;
            };
            let changed = store.borrow_mut().apply_from(frame, &client);
            settle(engine, Changes::changed(changed));
            // What the link serves is known now: what was held on the link
            // it replaced (one addressed to a cluster MC) moves to it.
            if frame.get("t").and_then(Value::as_str) == Some("shell")
                && let Some(own) = crate::controller::mc(engine)
            {
                own.reroute();
            }
        }),
        Some(resume),
    );
    slot.links
        .borrow_mut()
        .insert(environment_id.to_owned(), (link, id));
}

/// Holds what the cache kept of the saved environment `environment_id` as
/// its link's while it has no link (it is blocked), so the shell's own
/// snapshot does not take it: until [`remove_link`] or [`add_link`].
pub fn reserve_link(engine: &Engine, environment_id: &str) {
    if let Some(store) = get(engine) {
        store.borrow_mut().add_link(environment_id);
    }
}

/// Ends the link to `environment_id`: its MCs go when the environment is
/// `forget`ten (removed), else they stay until a client lists them again
/// (desktop-qt's ShellStore::removeLink).
pub fn remove_link(engine: &Engine, environment_id: &str, forget: bool) {
    let slot = engine.extension::<Slot>();
    let removed = slot.links.borrow_mut().remove(environment_id);
    if let Some((link, id)) = removed {
        link.unsubscribe(id);
    }
    if let Some(store) = get(engine) {
        let changed = store.borrow_mut().remove_link(environment_id, forget);
        settle(engine, Changes::changed(changed));
    }
}

/// Runs `f` once the store is installed: now when it is. For what is given
/// to the store's parts at start-up (the cache's wake) in a shell that may
/// have no MC yet and get its store when [`crate::open`] pairs it. A
/// listener ([`on_changed`]) needs no such hook: it is kept by the engine
/// and hears of a store that comes later.
pub fn when_installed(engine: &Engine, f: impl FnOnce(&Engine) + 'static) {
    if get(engine).is_some() {
        f(engine);
    } else {
        engine
            .extension::<Slot>()
            .installed
            .borrow_mut()
            .push(Box::new(f));
    }
}

/// The store, once installed.
pub fn get(engine: &Engine) -> Option<Rc<RefCell<ShellStore>>> {
    engine.extension::<Slot>().store.borrow().clone()
}

/// Reads the store; `R::default()` before one is installed. Never call into
/// the store's mutating functions from `f`.
pub fn with<R: Default>(engine: &Engine, f: impl FnOnce(&ShellStore) -> R) -> R {
    get(engine).map(|s| f(&s.borrow())).unwrap_or_default()
}

/// The cache the store keeps rows in, for the other stores that keep theirs
/// there (ThreadStore).
pub fn cache(engine: &Engine) -> Option<Rc<LocalCache>> {
    get(engine).and_then(|s| s.borrow().cache().cloned())
}

/// Runs `f` after every change of the store, outside any borrow of it.
pub fn on_changed(engine: &Engine, f: impl Fn(&Engine) + 'static) {
    engine
        .extension::<Slot>()
        .listeners
        .borrow_mut()
        .push(Rc::new(move |engine, changes: Changes| {
            if changes.changed {
                f(engine);
            }
        }));
}

/// Runs `f` when the store is opened at another MC than the one whose rows
/// it held, and when it is cleared, before the change listeners.
pub fn on_origin_changed(engine: &Engine, f: impl Fn(&Engine) + 'static) {
    engine
        .extension::<Slot>()
        .listeners
        .borrow_mut()
        .push(Rc::new(move |engine, changes: Changes| {
            if changes.origin_changed {
                f(engine);
            }
        }));
}

/// [`ShellStore::open`] on the engine's store.
pub fn open(engine: &Engine, origin: &str) {
    if let Some(store) = get(engine) {
        let changes = store.borrow_mut().open(origin);
        settle(engine, changes);
    }
}

/// [`ShellStore::show_kept`] on the engine's store.
pub fn show_kept(engine: &Engine) {
    if let Some(store) = get(engine) {
        store.borrow_mut().show_kept();
    }
}

/// Runs the cache's replies that are ready ([`LocalCache::deliver`]), and
/// holds the kept rows among them ([`ShellStore::take_kept`]).
pub fn deliver(engine: &Engine) {
    let Some(store) = get(engine) else { return };
    let cache = store.borrow().cache().cloned();
    if let Some(cache) = cache {
        cache.deliver();
    }
    let changes = store.borrow_mut().take_kept();
    settle(engine, changes);
}

/// [`ShellStore::clear`] on the engine's store; `done` hears false when the
/// cache could not be emptied.
pub fn clear(engine: &Engine, done: impl FnOnce(bool) + 'static) {
    let Some(store) = get(engine) else {
        return done(true);
    };
    store.borrow_mut().forget();
    // The threads shown go first (ThreadStore, on the origin change), so
    // nothing of theirs is written after the cache is emptied.
    settle(
        engine,
        Changes {
            changed: false,
            origin_changed: true,
        },
    );
    match cache(engine) {
        Some(cache) => cache.clear(done),
        None => done(true),
    }
    settle(engine, Changes::changed(true));
}

/// Writes what waits for the cache now (on exit, before a render).
pub fn flush(engine: &Engine) {
    let slot = engine.extension::<Slot>();
    if let Some(id) = slot.flush.take() {
        engine.cancel_call(id);
    }
    if let Some(store) = get(engine) {
        store.borrow_mut().flush();
    }
}

/// After the store changed: arms or drops the flush, then tells the
/// listeners, origin first.
fn settle(engine: &Engine, changes: Changes) {
    let slot = engine.extension::<Slot>();
    let due = with(engine, ShellStore::flush_due);
    match (due, slot.flush.get()) {
        (true, None) => {
            let at = engine.now() + Duration::from_millis(FLUSH_DELAY_MS);
            slot.flush.set(Some(engine.call_at(at, |engine| {
                engine.extension::<Slot>().flush.set(None);
                if let Some(store) = get(engine) {
                    store.borrow_mut().flush();
                }
            })));
        }
        (false, Some(id)) => {
            slot.flush.set(None);
            engine.cancel_call(id);
        }
        _ => {}
    }
    if !(changes.changed || changes.origin_changed) {
        return;
    }
    let listeners = slot.listeners.borrow().clone();
    for origin in [true, false] {
        for listener in &listeners {
            let only = Changes {
                changed: changes.changed && !origin,
                origin_changed: changes.origin_changed && origin,
            };
            if only.changed || only.origin_changed {
                listener(engine, only);
            }
        }
    }
}

#[cfg(test)]
mod tests;
