//! `archivedThreads`, desktop-qt's ArchivedThreadsController: the Archive
//! settings section ("/settings/archived"), which the shell owns. Every
//! archived thread the connected environments hold (or the settings scope's
//! environments and project hold), grouped by project, with a way back
//! (unarchive) and a way out (delete) for each.
//!
//! The list is fetched, not streamed (features/parity/rpc.feature): opening
//! the section, refreshing, an action landing, or the online environments
//! changing asks each reachable online environment for its
//! `orchestration.getArchivedShellSnapshot`.
//!
//! Publishes `archivedThreads`: {open, status: loading | error | empty |
//! ready, title, description (why nothing is listed), groups [{key, title,
//! threads [{key, environmentId, threadId, title, description, busy}]}]}.
//!
//! Actions: `archivedThreads.refresh`, `.unarchive {environmentId,
//! threadId}`, `.delete {environmentId, threadId}` (asks first when the
//! user wants deletes confirmed). The palette's "archivedThreads.open"
//! opens the section.

use std::collections::{HashMap, HashSet};
use std::rc::Rc;

use chrono::{DateTime, Utc};
use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::commands::Commands;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::menus::Menus;
use crate::controllers::navigation::{ARCHIVED_SECTION, Navigation, Route, at_section};
use crate::controllers::settings::Settings;
use crate::controllers::settings_scope::SettingsScope;
use crate::controllers::toasts::Toasts;
use crate::json::Json;
use crate::mc::Mc;
use crate::store;

const KEY: &str = "archivedThreads";

type Clock = Rc<dyn Fn() -> DateTime<Utc>>;

fn text<'a>(value: &'a Json, field: &str) -> &'a str {
    value.get(field).and_then(Json::as_str).unwrap_or_default()
}

/// "just now", then minutes, hours and days ago.
fn ago(iso: &str, now: DateTime<Utc>) -> String {
    let Ok(at) = DateTime::parse_from_rfc3339(iso) else {
        return String::new();
    };
    let seconds = (now - at.with_timezone(&Utc)).num_seconds().max(0);
    match seconds {
        0..=59 => "just now".into(),
        60..=3599 => format!("{}m ago", seconds / 60),
        3600..=86399 => format!("{}h ago", seconds / 3600),
        _ => format!("{}d ago", seconds / 86400),
    }
}

fn archived_at(thread: &Json) -> &str {
    match text(thread, "archivedAt") {
        "" => text(thread, "createdAt"),
        at => at,
    }
}

pub struct ArchivedThreads {
    bridge: Bridge,
    me: Me<ArchivedThreads>,
    mc: Rc<dyn Mc>,
    clock: Clock,
    active: bool,
    open: bool,
    /// The environments last asked, and which have not answered.
    asked: Vec<String>,
    pending: HashSet<String>,
    /// Bumped per load, so an answer to an older one is dropped.
    generation: u64,
    error: String,
    /// Each environment's answer: its projects and archived threads.
    projects: HashMap<String, Vec<Json>>,
    threads: HashMap<String, Vec<Json>>,
    /// Threads with an action in flight, by key.
    busy: HashSet<String>,
}

impl Controller for ArchivedThreads {
    fn new(init: Init<'_, Self>) -> Self {
        ArchivedThreads {
            bridge: init.bridge,
            me: init.me,
            mc: init.mc,
            clock: Rc::new(Utc::now),
            active: false,
            open: false,
            asked: Vec::new(),
            pending: HashSet::new(),
            generation: 0,
            error: String::new(),
            projects: HashMap::new(),
            threads: HashMap::new(),
            busy: HashSet::new(),
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let me = self.me.clone();
        self.bridge.watch(engine, "route", move |engine, route| {
            let open = at_section(route, ARCHIVED_SECTION);
            me.run(engine, |c, engine| c.set_open(engine, open));
        });
        // An environment that comes or goes changes whose archive can be
        // listed.
        let me = self.me.clone();
        store::on_changed(engine, move |engine| {
            me.run(engine, |c, engine| {
                if c.open && c.online(engine) != c.asked {
                    c.load(engine);
                }
            });
        });
        // The settings scope narrows the list to its environments and
        // project.
        let me = self.me.clone();
        SettingsScope::of(engine).on_changed(move |engine| {
            me.run(engine, |c, engine| {
                if c.open {
                    c.publish(engine);
                }
            });
        });
        let route = self.bridge.published(engine, "route");
        self.set_open(
            engine,
            route.is_some_and(|r| at_section(&r, ARCHIVED_SECTION)),
        );
        self.publish(engine);
    }

    fn attach(&mut self, engine: &Engine, _window: &crate::controller::Window) {
        Commands::of(engine).add(
            engine,
            "archivedThreads.open",
            "Open archived threads",
            |engine| {
                controller::with::<Navigation, _>(engine, |n, engine| {
                    n.open(engine, Route::Settings(ARCHIVED_SECTION.into()));
                });
            },
        );
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !self.active || !action.starts_with("archivedThreads.") {
            return false;
        }
        let environment_id = text(payload, "environmentId").to_owned();
        let thread_id = text(payload, "threadId").to_owned();
        match action {
            "archivedThreads.refresh" => self.load(engine),
            _ if environment_id.is_empty() || thread_id.is_empty() => {}
            "archivedThreads.unarchive" => self.act(
                engine,
                &environment_id,
                &thread_id,
                "thread.unarchive",
                "Failed to unarchive thread",
            ),
            "archivedThreads.delete" => {
                let confirm = Settings::of(engine)
                    .setting(engine, "confirmThreadDelete")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false);
                if !confirm {
                    self.act(
                        engine,
                        &environment_id,
                        &thread_id,
                        "thread.delete",
                        "Failed to delete thread",
                    );
                    return true;
                }
                let title = self
                    .threads
                    .get(&environment_id)
                    .into_iter()
                    .flatten()
                    .filter(|t| text(t, "id") == thread_id)
                    .map(|t| text(t, "title").to_owned())
                    .next_back()
                    .unwrap_or_else(|| thread_id.clone());
                let me = self.me.clone();
                let remove = Rc::new(move |engine: &Engine| {
                    let (environment_id, thread_id) = (environment_id.clone(), thread_id.clone());
                    me.run(engine, |c, engine| {
                        c.act(
                            engine,
                            &environment_id,
                            &thread_id,
                            "thread.delete",
                            "Failed to delete thread",
                        );
                    });
                });
                controller::with::<Menus, _>(engine, |menus, engine| {
                    menus.confirm(
                        engine,
                        &format!("Delete thread \"{title}\"?"),
                        "This permanently clears conversation history for this thread.",
                        "Delete",
                        true,
                        Some(remove),
                        None,
                    );
                });
            }
            _ => {}
        }
        true
    }
}

impl ArchivedThreads {
    /// Reads the time from `clock` instead of the system's.
    pub fn set_clock(&mut self, clock: impl Fn() -> DateTime<Utc> + 'static) {
        self.clock = Rc::new(clock);
    }

    fn set_open(&mut self, engine: &Engine, open: bool) {
        if open == self.open {
            return;
        }
        self.open = open;
        if open {
            self.load(engine);
        } else {
            // Nothing is kept for a section nobody sees; it is fetched fresh
            // next time.
            self.generation += 1;
            self.asked.clear();
            self.pending.clear();
            self.projects.clear();
            self.threads.clear();
            self.error.clear();
            self.publish(engine);
        }
    }

    /// The environments whose archive can be asked for: the online ones.
    fn online(&self, engine: &Engine) -> Vec<String> {
        store::with(engine, |s| {
            let mut ids: Vec<String> = Vec::new();
            for id in s.environments() {
                if s.environment_online(&id) && !ids.contains(&id) {
                    ids.push(id);
                }
            }
            ids
        })
    }

    fn load(&mut self, engine: &Engine) {
        if !self.open {
            return;
        }
        self.generation += 1;
        let generation = self.generation;
        self.asked = self.online(engine);
        self.pending = self.asked.iter().cloned().collect();
        self.error.clear();
        for environment_id in self.asked.clone() {
            let me = self.me.clone();
            let id = environment_id.clone();
            self.mc.call(
                &environment_id,
                "orchestration.getArchivedShellSnapshot",
                json!({}),
                Box::new(move |engine, result| {
                    me.run(engine, |c, engine| {
                        if generation != c.generation {
                            return;
                        }
                        c.pending.remove(&id);
                        match result {
                            Err(error) => c.error = error.message,
                            Ok(snapshot) => {
                                let list = |field: &str| {
                                    snapshot
                                        .get(field)
                                        .and_then(Json::as_array)
                                        .cloned()
                                        .unwrap_or_default()
                                };
                                c.projects.insert(id.clone(), list("projects"));
                                c.threads.insert(id, list("threads"));
                            }
                        }
                        c.publish(engine);
                    });
                }),
            );
        }
        self.publish(engine);
    }

    /// `type` on the thread, which unarchiving or deleting both are.
    fn act(
        &mut self,
        engine: &Engine,
        environment_id: &str,
        thread_id: &str,
        kind: &str,
        failure: &'static str,
    ) {
        let key = format!("{environment_id}:{thread_id}");
        if !self.busy.insert(key.clone()) {
            return;
        }
        self.publish(engine);
        let me = self.me.clone();
        let (environment, thread) = (environment_id.to_owned(), thread_id.to_owned());
        self.mc.dispatch_command(
            environment_id,
            json!({"type": kind, "threadId": thread_id}),
            Box::new(move |engine, result| {
                me.run(engine, |c, engine| {
                    c.busy.remove(&key);
                    match result {
                        Err(error) => {
                            let message = error.message;
                            Bridge::of(engine).defer(engine, move |engine| {
                                controller::with::<Toasts, _>(engine, |toasts, engine| {
                                    toasts.error(engine, failure, &message);
                                });
                            });
                            c.publish(engine);
                        }
                        Ok(_) => {
                            // Unarchived or deleted, it is not archived any
                            // more: the row goes now, not when the
                            // environment has listed them again.
                            if let Some(threads) = c.threads.get_mut(&environment) {
                                threads.retain(|t| text(t, "id") != thread);
                            }
                            c.load(engine);
                        }
                    }
                });
            }),
        );
    }

    fn publish(&mut self, engine: &Engine) {
        if !self.active {
            return;
        }
        let now = (self.clock)();
        let mut groups: Vec<Json> = Vec::new();
        // A picked environment or project lists only its threads.
        let scope = SettingsScope::of(engine);
        let scoped = scope.project_scope() || !scope.environment_filter().is_empty();
        if self.open {
            let covered = scope.environments(engine);
            for environment_id in &self.asked {
                if scoped && !covered.contains(environment_id) {
                    continue;
                }
                let mut threads: Vec<&Json> = self
                    .threads
                    .get(environment_id)
                    .into_iter()
                    .flatten()
                    .collect();
                // Newest archived first.
                threads.sort_by(|a, b| {
                    archived_at(b)
                        .cmp(archived_at(a))
                        .then_with(|| text(b, "id").cmp(text(a, "id")))
                });
                // One group per project, in the environment's project order;
                // a thread whose project is gone groups under its id.
                let mut order: Vec<String> = Vec::new();
                let mut titles: HashMap<String, String> = HashMap::new();
                for project in self.projects.get(environment_id).into_iter().flatten() {
                    let id = text(project, "id").to_owned();
                    order.push(id.clone());
                    let title = match text(project, "title") {
                        "" => id.clone(),
                        title => title.to_owned(),
                    };
                    titles.insert(id, title);
                }
                let mut rows: HashMap<String, Vec<Json>> = HashMap::new();
                for thread in threads {
                    let project_id = text(thread, "projectId");
                    if scoped && !scope.covers(engine, environment_id, project_id) {
                        continue;
                    }
                    if !order.iter().any(|p| p == project_id) {
                        order.push(project_id.to_owned());
                    }
                    let thread_id = text(thread, "id");
                    let key = format!("{environment_id}:{thread_id}");
                    rows.entry(project_id.to_owned()).or_default().push(json!({
                        "key": key,
                        "environmentId": environment_id,
                        "threadId": thread_id,
                        "title": text(thread, "title"),
                        "description": format!(
                            "Archived {} · Created {}",
                            ago(archived_at(thread), now),
                            ago(text(thread, "createdAt"), now),
                        ),
                        "busy": self.busy.contains(&key),
                    }));
                }
                for project_id in order {
                    let Some(threads) = rows.remove(&project_id) else {
                        continue;
                    };
                    groups.push(json!({
                        "key": format!("{environment_id}:{project_id}"),
                        "title": titles.get(&project_id).cloned().unwrap_or_else(|| project_id.clone()),
                        "threads": threads,
                    }));
                }
            }
        }
        let (mut status, mut title, mut description) = ("ready", String::new(), String::new());
        // A reload keeps what was listed until the answers come.
        if groups.is_empty()
            && (!self.pending.is_empty()
                || (self.open && !store::with(engine, |s| s.synchronized())))
        {
            status = "loading";
            title = "Loading archived threads".into();
            description = "Checking connected environments.".into();
        } else if !self.error.is_empty() {
            status = "error";
            title = "Could not load archived threads".into();
            description = self.error.clone();
        } else if groups.is_empty() {
            status = "empty";
            title = "No archived threads".into();
            description = "Archived threads will appear here.".into();
        }
        self.bridge.publish(
            engine,
            KEY,
            json!({
                "open": self.open,
                "status": status,
                "title": title,
                "description": description,
                "groups": groups,
            }),
        );
    }
}
