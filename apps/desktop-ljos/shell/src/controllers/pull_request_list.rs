//! `pullRequestList`, desktop-qt's PullRequestListController: the pull
//! requests page, which the shell owns (the route `pullRequests`). Every
//! reachable environment is asked for its pull requests (`pullRequests.list`,
//! apps/server-ex HalC2.PullRequests) under the chosen filters, and the
//! answers are merged, newest first, into the groups Authored, Review
//! requested, Others. While the page shows, each environment's
//! `pullRequestRefreshes` shape re-reads the list when a pull request changes
//! from HAL-C2.
//!
//! Publishes `pullRequestList`: {open, loading, filters {state, involvement,
//! draft, review, checks, query, environmentId, projectKey}, filtered, groups
//! [{id, label, rows}], count, environments [{id, label, status: loading |
//! ready | failed | offline, message}], environmentChoices [{id, label}],
//! problems [text], empty {title, body[, action]} | null, error {title,
//! message} | null, projects [{key, label}], notice {key, kind, text} |
//! null}.
//!
//! Actions: `pullRequestList.filter {name, value}` (kept on this device for
//! next time), `pullRequestList.refresh` (the hosts are asked afresh:
//! `pullRequests.invalidate`), `pullRequestList.open {key}` (the thread
//! working on it, `pullRequests.linkedThreads`) and
//! `pullRequestList.openOnHost {key}`. The palette's "pullRequests.refresh"
//! opens the page first. "Open pull requests" is Navigation's.

use std::cell::Cell;
use std::collections::{BTreeMap, HashMap};
use std::rc::Rc;

use ljos::prelude::Engine;
use serde_json::{Map, json};

use crate::bridge::Bridge;
use crate::commands::Commands;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::navigation::{Navigation, Route, at_kind};
use crate::controllers::settings::Settings;
use crate::json::Json;
use crate::keybindings as keymap;
use crate::mc::{Mc, SubId};
use crate::store;

const KEY: &str = "pullRequestList";
/// Where the filters are kept on this device.
const PREFERENCES: &str = "pullRequestList";
/// As many as the MC lists by default.
const LIMIT: i64 = 99;

/// The filters and their defaults.
const DEFAULTS: [(&str, &str); 8] = [
    ("state", "open"),
    ("involvement", "all"),
    ("draft", ""),
    ("review", ""),
    ("checks", ""),
    ("query", ""),
    ("environmentId", ""),
    ("projectKey", ""),
];

/// What a filter may be set to; the rest are free text or ids.
fn choices(name: &str) -> Option<&'static [&'static str]> {
    Some(match name {
        "state" => &["all", "open", "closed", "merged"],
        "involvement" => &["all", "reviewing", "authored"],
        "draft" => &["", "only", "hide"],
        "review" => &[
            "",
            "approved",
            "changes-requested",
            "review-required",
            "none",
        ],
        "checks" => &["", "passing", "failing"],
        _ => return None,
    })
}

fn default_of(name: &str) -> Option<&'static str> {
    DEFAULTS.iter().find(|(n, _)| *n == name).map(|(_, v)| *v)
}

fn text<'a>(value: &'a Json, field: &str) -> &'a str {
    value.get(field).and_then(Json::as_str).unwrap_or_default()
}

fn int(value: &Json, field: &str) -> i64 {
    value
        .get(field)
        .and_then(Json::as_f64)
        .map_or(0, |n| n as i64)
}

fn row_key(environment_id: &str, entry: &Json) -> String {
    format!(
        "{environment_id}:{}:{}#{}",
        text(entry, "host"),
        text(entry, "repository"),
        int(entry, "number")
    )
}

#[derive(Clone, Default)]
struct Answer {
    /// loading, ready, failed, offline
    status: String,
    message: String,
    result: Json,
}

pub struct PullRequestList {
    bridge: Bridge,
    me: Me<PullRequestList>,
    mc: Rc<dyn Mc>,
    active: bool,
    open: bool,
    filters: BTreeMap<&'static str, String>,
    answers: HashMap<String, Answer>,
    /// Each environment's live `pullRequestRefreshes`, and the revision it
    /// last said.
    subscriptions: HashMap<String, SubId>,
    revisions: HashMap<String, i64>,
    notice: Json,
    /// Bumped by every read; an answer lands only if nothing was asked since.
    generation: u64,
}

impl Controller for PullRequestList {
    fn new(init: Init<'_, Self>) -> Self {
        PullRequestList {
            bridge: init.bridge,
            me: init.me,
            mc: init.mc,
            active: false,
            open: false,
            filters: DEFAULTS
                .iter()
                .map(|(n, v)| (*n, (*v).to_owned()))
                .collect(),
            answers: HashMap::new(),
            subscriptions: HashMap::new(),
            revisions: HashMap::new(),
            notice: Json::Null,
            generation: 0,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let kept = Settings::of(engine)
            .device_value(PREFERENCES)
            .unwrap_or(Json::Null);
        for (name, _) in DEFAULTS {
            let Some(value) = kept.get(name).and_then(Json::as_str) else {
                continue;
            };
            if choices(name).is_none_or(|c| c.contains(&value)) {
                self.filters.insert(name, value.to_owned());
            }
        }
        let me = self.me.clone();
        self.bridge.watch(engine, "route", move |engine, route| {
            let open = at_kind(route, "pullRequests");
            me.run(engine, |c, engine| c.set_open(engine, open));
        });
        // An environment that comes back (or goes) changes who is asked.
        let me = self.me.clone();
        store::on_changed(engine, move |engine| {
            me.run(engine, |c, engine| c.environments_changed(engine));
        });
        let route = self.bridge.published(engine, "route");
        self.set_open(engine, route.is_some_and(|r| at_kind(&r, "pullRequests")));
        self.publish(engine);
    }

    fn attach(&mut self, engine: &Engine, _window: &crate::controller::Window) {
        Commands::of(engine).add(
            engine,
            "pullRequests.refresh",
            &keymap::command_label("pullRequests.refresh"),
            |engine| {
                let bridge = Bridge::of(engine);
                if !bridge
                    .published(engine, "route")
                    .is_some_and(|r| at_kind(&r, "pullRequests"))
                {
                    controller::with::<Navigation, _>(engine, |n, engine| {
                        n.open(engine, Route::PullRequests)
                    });
                }
                bridge.dispatch(engine, "pullRequestList.refresh", Json::Null);
            },
        );
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !self.active || !action.starts_with("pullRequestList.") {
            return false;
        }
        match action {
            "pullRequestList.filter" => {
                let name = text(payload, "name");
                let value = text(payload, "value");
                if default_of(name).is_none() {
                    return true;
                }
                if choices(name).is_some_and(|c| !c.contains(&value)) {
                    return true;
                }
                let name = DEFAULTS
                    .iter()
                    .find(|(n, _)| *n == name)
                    .map_or("", |(n, _)| *n);
                if self.filters.get(name).map(String::as_str) == Some(value) {
                    return true;
                }
                self.filters.insert(name, value.to_owned());
                let kept: Map<String, Json> = DEFAULTS
                    .iter()
                    .filter(|(n, d)| self.filters.get(n).map(String::as_str) != Some(*d))
                    .map(|(n, _)| ((*n).to_owned(), Json::from(self.filters[n].clone())))
                    .collect();
                Settings::of(engine).write_device(engine, PREFERENCES, Json::Object(kept));
                self.load(engine);
            }
            "pullRequestList.refresh" => self.refresh(engine),
            "pullRequestList.open" => self.open_row(engine, text(payload, "key")),
            "pullRequestList.openOnHost" => {
                let url = self
                    .row(text(payload, "key"))
                    .map(|entry| text(&entry, "url").to_owned())
                    .unwrap_or_default();
                if !url.is_empty() {
                    self.bridge.open_external(engine, &url);
                }
            }
            _ => return false,
        }
        true
    }
}

impl PullRequestList {
    fn filter(&self, name: &str) -> &str {
        self.filters.get(name).map_or("", String::as_str)
    }

    fn online(&self, engine: &Engine, id: &str) -> bool {
        store::with(engine, |s| s.environment_online(id))
    }

    fn set_open(&mut self, engine: &Engine, open: bool) {
        if open == self.open {
            return;
        }
        self.open = open;
        if !open {
            // Nothing is read for a page nobody sees.
            self.generation += 1;
            self.unsubscribe();
            self.notice = Json::Null;
            self.publish(engine);
            return;
        }
        self.load(engine);
    }

    fn environments_changed(&mut self, engine: &Engine) {
        if !self.open {
            return;
        }
        let now = self.targets(engine);
        let mut asked: Vec<String> = self.answers.keys().cloned().collect();
        let mut wanted = now.clone();
        asked.sort();
        wanted.sort();
        let mut changed = asked != wanted;
        for id in &now {
            let offline = self.answers.get(id).is_some_and(|a| a.status == "offline");
            if offline == self.online(engine, id) {
                changed = true;
            }
        }
        if changed {
            self.load(engine);
        }
    }

    /// The environments asked: every one of the cluster, or the one the
    /// filters name.
    fn targets(&self, engine: &Engine) -> Vec<String> {
        let mut only = self.filter("environmentId").to_owned();
        let project = self.filter("projectKey");
        if !project.is_empty() {
            only = project.split(':').next().unwrap_or_default().to_owned();
        }
        store::with(engine, |s| s.environments())
            .into_iter()
            .filter(|id| only.is_empty() || *id == only)
            .collect()
    }

    fn input(&self, environment_id: &str) -> Json {
        let mut filters = Map::new();
        for name in ["draft", "review", "checks"] {
            let value = self.filter(name);
            if !value.is_empty() {
                filters.insert(name.into(), value.into());
            }
        }
        let mut payload = Map::new();
        payload.insert("state".into(), self.filter("state").into());
        payload.insert("involvement".into(), self.filter("involvement").into());
        payload.insert("limit".into(), LIMIT.into());
        if !filters.is_empty() {
            payload.insert("filters".into(), Json::Object(filters));
        }
        let query = self.filter("query").trim();
        if !query.is_empty() {
            payload.insert("query".into(), query.into());
        }
        if let Some((environment, project_id)) = self.filter("projectKey").split_once(':')
            && environment == environment_id
        {
            payload.insert("projectId".into(), project_id.into());
        }
        Json::Object(payload)
    }

    fn load(&mut self, engine: &Engine) {
        if !self.open {
            return;
        }
        self.generation += 1;
        let generation = self.generation;
        let mut answers = HashMap::new();
        for id in self.targets(engine) {
            // The last answer stays on screen until the new one lands.
            let mut answer = self.answers.get(&id).cloned().unwrap_or_default();
            if self.online(engine, &id) {
                answer.status = "loading".into();
            } else {
                answer = Answer {
                    status: "offline".into(),
                    ..Answer::default()
                };
            }
            answers.insert(id, answer);
        }
        self.answers = answers;
        let mut loading: Vec<String> = self
            .answers
            .iter()
            .filter(|(_, a)| a.status == "loading")
            .map(|(id, _)| id.clone())
            .collect();
        loading.sort();
        for id in loading {
            let me = self.me.clone();
            let environment_id = id.clone();
            self.mc.call(
                &id,
                "pullRequests.list",
                self.input(&id),
                Box::new(move |engine, result| {
                    me.run(engine, |c, engine| {
                        if generation != c.generation || !c.answers.contains_key(&environment_id) {
                            return;
                        }
                        let answer = match result {
                            Err(error) => Answer {
                                status: "failed".into(),
                                message: error.message,
                                result: Json::Null,
                            },
                            Ok(result) => Answer {
                                status: "ready".into(),
                                message: String::new(),
                                result,
                            },
                        };
                        c.answers.insert(environment_id, answer);
                        c.publish(engine);
                    });
                }),
            );
        }
        self.subscribe(engine);
        self.publish(engine);
    }

    /// The hosts are asked afresh, then everything is read again.
    fn refresh(&mut self, engine: &Engine) {
        if !self.open {
            return;
        }
        let online: Vec<String> = self
            .targets(engine)
            .into_iter()
            .filter(|id| self.online(engine, id))
            .collect();
        if online.is_empty() {
            self.load(engine);
            return;
        }
        // Forgetting cached answers bumps the refresh revision too; the read
        // after every environment has forgotten is the one that counts.
        let remaining = Rc::new(Cell::new(online.len()));
        for id in online {
            let me = self.me.clone();
            let remaining = remaining.clone();
            self.mc.call(
                &id,
                "pullRequests.invalidate",
                json!({}),
                Box::new(move |engine, _| {
                    remaining.set(remaining.get() - 1);
                    if remaining.get() == 0 {
                        me.run(engine, |c, engine| c.load(engine));
                    }
                }),
            );
        }
    }

    /// While the page shows, each environment says when its pull requests
    /// changed.
    fn subscribe(&mut self, engine: &Engine) {
        let environments = self.targets(engine);
        let gone: Vec<String> = self
            .subscriptions
            .keys()
            .filter(|id| !environments.contains(id) || !self.online(engine, id))
            .cloned()
            .collect();
        for id in gone {
            if let Some(sub) = self.subscriptions.remove(&id) {
                self.mc.unsubscribe(sub);
            }
            self.revisions.remove(&id);
        }
        for id in environments {
            if self.subscriptions.contains_key(&id) || !self.online(engine, &id) {
                continue;
            }
            let me = self.me.clone();
            let environment_id = id.clone();
            let sub = self.mc.subscribe(
                json!({"type": "pullRequestRefreshes", "environment": id}),
                Box::new(move |engine, frame| {
                    if frame.get("t").and_then(Json::as_str) != Some("pullRequestRefreshes") {
                        return;
                    }
                    let revision = frame
                        .get("revision")
                        .and_then(Json::as_f64)
                        .map_or(0, |n| n as i64);
                    me.run(engine, |c, engine| {
                        // The first frame is where the MC is now; only a
                        // later one is news.
                        let last = c.revisions.insert(environment_id.clone(), revision);
                        if last.is_some_and(|last| last != revision) {
                            c.load(engine);
                        }
                    });
                }),
                None,
            );
            self.subscriptions.insert(id, sub);
        }
    }

    fn unsubscribe(&mut self) {
        for (_, sub) in self.subscriptions.drain() {
            self.mc.unsubscribe(sub);
        }
        self.revisions.clear();
    }

    /// The entry listed under `key`, with the environment that listed it.
    fn row(&self, key: &str) -> Option<Json> {
        self.answers.iter().find_map(|(id, answer)| {
            let entries = answer.result.get("entries")?.as_array()?;
            let mut found = entries
                .iter()
                .find(|entry| row_key(id, entry) == key)?
                .clone();
            found
                .as_object_mut()?
                .insert("environmentId".into(), id.clone().into());
            Some(found)
        })
    }

    /// The thread working on the pull request opens; with none, the dialog
    /// offers to start one.
    fn open_row(&mut self, engine: &Engine, key: &str) {
        let Some(entry) = self.row(key) else { return };
        let environment_id = text(&entry, "environmentId").to_owned();
        let project_id = text(&entry, "projectId").to_owned();
        let url = text(&entry, "url").to_owned();
        let mut reference = Map::new();
        reference.insert("projectId".into(), project_id.clone().into());
        reference.insert("repository".into(), text(&entry, "repository").into());
        reference.insert("number".into(), int(&entry, "number").into());
        if !text(&entry, "host").is_empty() {
            reference.insert("host".into(), text(&entry, "host").into());
        }
        self.notice = Json::Null;
        self.publish(engine);
        let me = self.me.clone();
        let key = key.to_owned();
        self.mc.call(
            &environment_id.clone(),
            "pullRequests.linkedThreads",
            Json::Object(reference),
            Box::new(move |engine, result| {
                me.run(engine, |c, engine| {
                    if !c.open {
                        return;
                    }
                    let result = match result {
                        Ok(result) => result,
                        Err(error) => {
                            c.notice = json!({"key": key, "kind": "error", "text": error.message});
                            c.publish(engine);
                            return;
                        }
                    };
                    // Newest first; an archived thread only when there is no
                    // other.
                    let mut thread_id = String::new();
                    for thread in result
                        .get("threads")
                        .and_then(Json::as_array)
                        .into_iter()
                        .flatten()
                    {
                        let archived = thread.get("archivedAt").is_some_and(|a| !a.is_null());
                        if thread_id.is_empty() {
                            thread_id = text(thread, "id").to_owned();
                        }
                        if !archived {
                            thread_id = text(thread, "id").to_owned();
                            break;
                        }
                    }
                    if thread_id.is_empty() {
                        // The dialog resolves it and offers a thread on it,
                        // or its checkout.
                        c.bridge.dispatch(
                            engine,
                            "pullRequestThread.open",
                            json!({
                                "reference": url,
                                "environmentId": environment_id,
                                "projectId": project_id,
                            }),
                        );
                        return;
                    }
                    // After this controller is let go: the route it publishes
                    // reaches this controller's own watch.
                    let route = Route::Thread(format!("{environment_id}:{thread_id}"));
                    c.bridge.defer(engine, move |engine| {
                        controller::with::<Navigation, _>(engine, |n, engine| {
                            n.open(engine, route)
                        });
                    });
                });
            }),
        );
    }

    fn publish(&mut self, engine: &Engine) {
        if !self.active {
            return;
        }
        let environment_ids = store::with(engine, |s| s.environments());
        let label_of = |id: &str| -> String {
            let label = store::with(engine, |s| {
                s.environment(id)
                    .get("label")
                    .and_then(Json::as_str)
                    .unwrap_or_default()
                    .to_owned()
            });
            if label.is_empty() {
                id.to_owned()
            } else {
                label
            }
        };
        let several = environment_ids.len() > 1;
        let mut environments = Vec::new();
        let mut problems: Vec<String> = Vec::new();
        let mut rows: Vec<Map<String, Json>> = Vec::new();
        let mut loading = false;
        let mut failures: Vec<String> = Vec::new();
        let mut ids: Vec<&String> = self.answers.keys().collect();
        ids.sort();
        for id in &ids {
            let answer = &self.answers[*id];
            let name = label_of(id);
            environments.push(json!({
                "id": id,
                "label": name,
                "status": answer.status,
                "message": answer.message,
            }));
            if answer.status == "loading" {
                loading = true;
            }
            if answer.status == "offline" {
                problems.push(format!(
                    "{name} cannot be reached; its pull requests are not listed."
                ));
            } else if answer.status == "failed" {
                failures.push(answer.message.clone());
                problems.push(if several {
                    format!("{name}: {}", answer.message)
                } else {
                    answer.message.clone()
                });
            }
            let viewers = answer.result.get("viewers").cloned().unwrap_or(Json::Null);
            for error in answer
                .result
                .get("errors")
                .and_then(Json::as_array)
                .into_iter()
                .flatten()
            {
                // The MC phrases the reason (and keeps the host's own text in
                // `detail`); the project is named here, once.
                let reason = text(error, "reason");
                problems.push(if reason.is_empty() {
                    format!(
                        "{}: {}",
                        text(error, "projectTitle"),
                        text(error, "message")
                    )
                } else {
                    format!(
                        "{} could not be read: {reason}",
                        text(error, "projectTitle")
                    )
                });
            }
            for entry in answer
                .result
                .get("entries")
                .and_then(Json::as_array)
                .into_iter()
                .flatten()
            {
                let author = entry.get("author").cloned().unwrap_or(Json::Null);
                let labels: Vec<&str> = entry
                    .get("labels")
                    .and_then(Json::as_array)
                    .into_iter()
                    .flatten()
                    .map(|l| text(l, "name"))
                    .collect();
                let login = text(&author, "login");
                let viewer = text(&viewers, text(entry, "host"));
                let group = if !viewer.is_empty() && login == viewer {
                    "authored"
                } else if entry
                    .get("viewerReviewRequested")
                    .and_then(Json::as_bool)
                    .unwrap_or(false)
                {
                    "reviewRequested"
                } else {
                    "others"
                };
                let mut row = Map::new();
                let mut put = |field: &str, value: Json| {
                    row.insert(field.into(), value);
                };
                put("key", row_key(id, entry).into());
                put("group", group.into());
                put("environmentId", (*id).clone().into());
                put(
                    "environmentLabel",
                    if several { name.clone() } else { String::new() }.into(),
                );
                put("projectTitle", text(entry, "projectTitle").into());
                put("repository", text(entry, "repository").into());
                put("number", int(entry, "number").into());
                put("title", text(entry, "title").into());
                put("url", text(entry, "url").into());
                put("state", text(entry, "state").into());
                put(
                    "isDraft",
                    entry
                        .get("isDraft")
                        .and_then(Json::as_bool)
                        .unwrap_or(false)
                        .into(),
                );
                put(
                    "author",
                    if login.is_empty() { "ghost" } else { login }.into(),
                );
                put("headBranch", text(entry, "headBranch").into());
                put("baseBranch", text(entry, "baseBranch").into());
                put("updatedAt", text(entry, "updatedAt").into());
                put("reviewDecision", text(entry, "reviewDecision").into());
                put("checksState", text(entry, "checksState").into());
                put(
                    "conflicting",
                    (text(entry, "mergeability") == "conflicting").into(),
                );
                put("additions", int(entry, "additions").into());
                put("deletions", int(entry, "deletions").into());
                put("labels", labels.into());
                rows.push(row);
            }
        }
        let updated = |row: &Map<String, Json>| {
            row.get("updatedAt")
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        rows.sort_by_key(|row| std::cmp::Reverse(updated(row)));
        let mut groups = Vec::new();
        for (id, label) in [
            ("authored", "Authored"),
            ("reviewRequested", "Review requested"),
            ("others", "Others"),
        ] {
            let members: Vec<&Map<String, Json>> = rows
                .iter()
                .filter(|r| r.get("group").and_then(Json::as_str) == Some(id))
                .collect();
            if !members.is_empty() {
                groups.push(json!({"id": id, "label": label, "rows": members}));
            }
        }

        let filtered = DEFAULTS
            .iter()
            .any(|(name, default)| *name != "query" && self.filter(name) != *default);
        let query = self.filter("query").trim();
        let mut empty = Json::Null;
        let mut error = Json::Null;
        let answered = ids.iter().any(|id| self.answers[*id].status == "ready");
        if rows.is_empty() && !loading {
            if !answered && !failures.is_empty() {
                error = json!({"title": "Could not load pull requests", "message": failures[0]});
            } else if store::with(engine, |s| s.projects().is_empty()) {
                empty = json!({
                    "title": "No projects in this workspace",
                    "body": "Add a project, and the pull requests from its repository appear here.",
                    "action": "project.add",
                });
            } else if !query.is_empty() {
                let shown: String = if query.chars().count() > 48 {
                    format!("{}…", query.chars().take(48).collect::<String>())
                } else {
                    query.to_owned()
                };
                empty = json!({
                    "title": format!("Nothing matches “{shown}”"),
                    "body": "The hosts were searched for it. Try fewer words, or search by number, author or branch.",
                });
            } else if filtered {
                empty = json!({
                    "title": "Nothing under these filters",
                    "body": "Widen the state, involvement or project filter to see more.",
                });
            } else if answered {
                empty = json!({
                    "title": "No pull requests",
                    "body": "Pull requests from every project in this workspace appear here.",
                });
            }
        }

        let environment_choices: Vec<Json> = environment_ids
            .iter()
            .map(|id| json!({"id": id, "label": label_of(id)}))
            .collect();
        let projects: Vec<Json> = store::with(engine, |s| {
            s.projects()
                .iter()
                .map(|p| json!({"key": p.key(), "label": p.title}))
                .collect()
        });
        let count = rows.len();
        self.bridge.publish(
            engine,
            KEY,
            json!({
                "open": self.open,
                "loading": loading,
                "filters": self.filters,
                "filtered": filtered,
                "groups": groups,
                "count": count,
                "environments": environments,
                "environmentChoices": environment_choices,
                "problems": problems,
                "empty": empty,
                "error": error,
                "projects": projects,
                "notice": self.notice,
            }),
        );
    }
}
