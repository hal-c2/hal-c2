//! desktop-qt's ThreadPullRequests: the Pull requests tab, the pull requests
//! linked to a thread (its row's `pullRequests`, synced by the MC) and the
//! project's open ones that are not.
//!
//! `link(text)` takes a pull request URL, or a bare `123` / `#123` for the
//! thread's own repository, and dispatches `thread.pull-request.link`; the
//! row comes when the thread's row does. `unlink(key)` dispatches
//! `thread.pull-request.unlink`, `refresh()` asks the MC to read every linked
//! one again (`pullRequests.invalidate`) and the project's list
//! (`pullRequests.list`).
//!
//! [`PullRequests`] is the core: it takes the thread's row and the MC's
//! replies and says what to ask of the MC as [`Effect`]s.
//! [`ThreadPullRequests`] is the object QML binds; the right panel points it
//! at the thread shown, and it runs those effects on the shell's MC.

use std::hash::{Hash, Hasher};
use std::rc::Rc;
use std::sync::LazyLock;

use ljos::prelude::{Atom, Cx, Engine, ObjectId, QmlObject, QmlValue, Value, qml_impl};
use ljos::prelude::{EngineError, RowKey};
use regex::Regex;
use serde_json::{Map, json};

use super::rows::{ListRows, RowChange, RowSource, int};
use crate::json::Json;
use crate::mc::{Mc, McError};
use crate::store;

pub const ROLES: &[&str] = &[
    "linkKey",
    "host",
    "repository",
    "number",
    "url",
    "title",
    "state",
    "stateLabel",
    "checks",
    "checksLabel",
    "review",
    "reviewLabel",
    "conflicting",
    "additions",
    "deletions",
    "author",
    "branches",
    "source",
    "sourceLabel",
    "unlinkLabel",
    "stackLabel",
];

fn text<'a>(object: &'a Json, key: &str) -> &'a str {
    object.get(key).and_then(Json::as_str).unwrap_or("")
}

/// QJsonValue::toInt(fallback): a whole number in range, else `fallback`.
fn int_of(object: &Json, key: &str, fallback: i64) -> i64 {
    object
        .get(key)
        .and_then(Json::as_i64)
        .filter(|n| i32::try_from(*n).is_ok())
        .unwrap_or(fallback)
}

fn snapshot_of(link: &Json) -> &Json {
    static NONE: Json = Json::Null;
    link.get("snapshot")
        .filter(|s| s.is_object())
        .unwrap_or(&NONE)
}

/// `host/repository#number`, lowercased: what names a linked pull request
/// here and in the panel's review tabs.
pub fn key_of(link: &Json) -> String {
    format!(
        "{}/{}#{}",
        text(link, "host").to_lowercase(),
        text(link, "repository").to_lowercase(),
        int_of(link, "number", 0)
    )
}

fn row_key(link: &Json) -> RowKey {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    key_of(link).hash(&mut hasher);
    hasher.finish()
}

/// A pull request named: where, and its page.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Target {
    pub host: String,
    pub repository: String,
    pub number: i64,
    pub url: String,
}

fn host_of(host: &str, apex: &str, label: &str) -> bool {
    host == apex
        || host.ends_with(&format!(".{apex}"))
        || (!label.is_empty() && host.split('.').any(|part| part == label))
}

fn azure_host(host: &str) -> bool {
    host_of(host, "dev.azure.com", "") || host.ends_with(".visualstudio.com")
}

/// A repository's pull request page, as the MC builds it
/// (mcp/tools/pull_requests.ex url/4) from the host alone.
pub fn page_of(host: &str, repository: &str, number: i64) -> String {
    if host_of(host, "gitlab.com", "gitlab") {
        format!("https://{host}/{repository}/-/merge_requests/{number}")
    } else if host_of(host, "bitbucket.org", "bitbucket") {
        format!("https://{host}/{repository}/pull-requests/{number}")
    } else if azure_host(host) {
        format!("https://{host}/{repository}/pullrequest/{number}")
    } else {
        format!("https://{host}/{repository}/pull/{number}")
    }
}

/// The host a project's checkout reads (`github.com/acme/shop` gives
/// github.com) and its repository, lowercased; empty without one.
pub fn repository_of(project: &Map<String, Json>) -> (String, String) {
    let key = project
        .get("repositoryIdentity")
        .and_then(|i| i.get("canonicalKey"))
        .and_then(Json::as_str)
        .unwrap_or("")
        .to_lowercase();
    match key.find('/') {
        Some(slash) if slash > 0 => (key[..slash].to_owned(), key[slash + 1..].to_owned()),
        _ => (String::new(), String::new()),
    }
}

/// One name for an Azure DevOps repository however it is reached, over SSH,
/// visualstudio.com or dev.azure.com.
fn canonical_key(key: &str) -> String {
    static SSH: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r"^(?:ssh\.dev\.azure\.com|vs-ssh\.visualstudio\.com)/v3/([^/]+)/([^/]+)/([^/]+)$",
        )
        .expect("a valid pattern")
    });
    static LEGACY: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"^([^.]+)\.visualstudio\.com/(?:defaultcollection/)?([^/]+)/_git/([^/]+)$")
            .expect("a valid pattern")
    });
    let key = SSH.replace(key, "dev.azure.com/$1/$2/_git/$3");
    LEGACY
        .replace(&key, "dev.azure.com/$1/$2/_git/$3")
        .into_owned()
}

/// The host, repository and number behind a pull request URL, as the MC
/// parses it (projection/pull_requests.ex parse_change_request_url/1).
pub fn parse_url(url: &str) -> Option<Target> {
    static GITHUB: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"^/([^/]+/[^/]+)/pull/([0-9]+)(?:/|$)").expect("a valid pattern")
    });
    static FORGEJO: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"^/([^/]+(?:/[^/]+)+)/pulls/([0-9]+)(?:/|$)").expect("a valid pattern")
    });
    static GITLAB: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"^/([^/]+(?:/[^/]+)+)/-/merge_requests/([0-9]+)(?:/|$)")
            .expect("a valid pattern")
    });
    static BITBUCKET: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"^/([^/]+/[^/]+)/pull-requests/([0-9]+)(?:/|$)").expect("a valid pattern")
    });
    static AZURE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"^/((?:[^/]+/)*_git/[^/]+)/pullrequest/([0-9]+)(?:/|$)")
            .expect("a valid pattern")
    });
    let trimmed = url.trim();
    let parsed = url::Url::parse(trimmed).ok()?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return None;
    }
    let mut host = parsed.host_str().filter(|h| !h.is_empty())?.to_lowercase();
    let path = match parsed.path() {
        "" => "/",
        path => path,
    };
    let found = if host_of(&host, "github.com", "github") && GITHUB.is_match(path) {
        GITHUB.captures(path)
    } else if let Some(found) = FORGEJO.captures(path) {
        // Forgejo and Gitea keep a port that is not the scheme's (which
        // the URL already leaves out).
        if let Some(port) = parsed.port() {
            host = format!("{host}:{port}");
        }
        Some(found)
    } else if let Some(found) = GITLAB.captures(path) {
        Some(found)
    } else if host_of(&host, "bitbucket.org", "bitbucket") {
        BITBUCKET.captures(path)
    } else if azure_host(&host) {
        AZURE.captures(path)
    } else {
        None
    }?;
    let number = found[2].parse::<i32>().ok().filter(|n| *n > 0)?;
    Some(Target {
        host,
        repository: found[1].to_lowercase(),
        number: number.into(),
        url: trimmed.to_owned(),
    })
}

/// The repositories a thread's environment reads: its projects' (host,
/// repository), and the thread's own project's.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Repositories {
    pub readable: Vec<(String, String)>,
    pub own: (String, String),
}

/// What `input` names. A URL may name any repository on a host a project
/// here reads, since that project lends the MC its credentials there
/// (findProjectOnChangeRequestHost); Azure DevOps reads with the checkout's
/// own organization and project, so there it takes a project of that
/// repository. A bare number means the thread's own repository.
pub fn resolve(input: &str, repositories: &Repositories) -> Result<Target, String> {
    static BARE: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"^#?([0-9]+)$").expect("a valid pattern"));
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return Err("Paste a pull request URL or enter 123 / #123.".into());
    }
    if let Some(target) = parse_url(trimmed) {
        let host = target.host.split(':').next().unwrap_or("");
        let wanted = canonical_key(&format!("{}/{}", target.host, target.repository));
        let azure = wanted.starts_with("dev.azure.com/");
        let readable = repositories.readable.iter().any(|(h, r)| {
            if azure {
                canonical_key(&format!("{h}/{r}")) == wanted
            } else {
                h == host
            }
        });
        if !readable {
            return Err(format!(
                "No project in this environment can read {}/{}.",
                target.host, target.repository
            ));
        }
        return Ok(target);
    }
    let number = BARE
        .captures(trimmed)
        .and_then(|c| c[1].parse::<i32>().ok())
        .filter(|n| *n > 0)
        .ok_or("Use a pull request URL, 123, or #123.")?;
    let (host, repository) = &repositories.own;
    if host.is_empty() || repository.is_empty() {
        return Err("Paste a full URL to link a pull request from another repository.".into());
    }
    let number = i64::from(number);
    Ok(Target {
        host: host.clone(),
        repository: repository.clone(),
        number,
        url: page_of(host, repository, number),
    })
}

/// What a row of `link` shows as `role`.
pub fn shown(link: &Json, role: &str) -> Value {
    let snapshot = snapshot_of(link);
    let synced = snapshot.is_object();
    let state = if !synced {
        "unknown"
    } else if snapshot.get("isDraft").and_then(Json::as_bool) == Some(true)
        && text(snapshot, "state") == "open"
    {
        "draft"
    } else {
        text(snapshot, "state")
    };
    let label = |s: &str| Value::from(s);
    match role {
        "linkKey" => Value::from(key_of(link).as_str()),
        "host" | "repository" | "url" | "source" => label(text(link, role)),
        "number" => Value::Int(int_of(link, "number", 0) as i32),
        "title" => label(text(snapshot, "title")),
        "state" => label(state),
        "stateLabel" => match state {
            "unknown" => label("Waiting for host state"),
            "" => label(""),
            state => {
                let mut chars = state.chars();
                let first = chars.next().map(|c| c.to_uppercase().collect::<String>());
                Value::from(format!("{}{}", first.unwrap_or_default(), chars.as_str()).as_str())
            }
        },
        "checks" => label(text(snapshot, "checksState")),
        "checksLabel" => label(match text(snapshot, "checksState") {
            "passing" => "Checks passing",
            "failing" => "Checks failing",
            "pending" => "Checks running",
            _ => "",
        }),
        "review" => label(text(snapshot, "reviewDecision")),
        "reviewLabel" => label(match text(snapshot, "reviewDecision") {
            "approved" => "Approved",
            "changes-requested" => "Changes requested",
            "review-required" => "Review required",
            _ => "",
        }),
        "conflicting" => Value::Bool(text(snapshot, "mergeability") == "conflicting"),
        "additions" | "deletions" => Value::Int(int_of(snapshot, role, -1) as i32),
        "author" => label(text(snapshot, "author")),
        "branches" => {
            let (head, base) = (text(snapshot, "headBranch"), text(snapshot, "baseBranch"));
            if head.is_empty() || base.is_empty() {
                label("")
            } else {
                Value::from(format!("{head} → {base}").as_str())
            }
        }
        // ThreadPullRequestsPanel's SOURCE_LABELS.
        "sourceLabel" => label(match text(link, "source") {
            "manual" => "Linked by you",
            "created" => "Created from this thread",
            "agent" => "Linked by the agent",
            "stack" => "Found in the stack",
            _ => "",
        }),
        "stackLabel" => {
            let layers = link
                .get("stack")
                .and_then(|s| s.get("layers"))
                .and_then(Json::as_array)
                .map(Vec::as_slice)
                .unwrap_or_default();
            let number = int_of(link, "number", 0);
            match layers
                .iter()
                .position(|layer| int_of(layer, "number", 0) == number)
            {
                Some(at) => Value::from(format!("Layer {} of {}", at + 1, layers.len()).as_str()),
                None => label(""),
            }
        }
        "unlinkLabel" => label(if text(link, "source") == "stack" {
            "Dismiss from thread"
        } else {
            "Unlink from thread"
        }),
        _ => Value::Undefined,
    }
}

/// What a reply is for. A generation is the thread's: a reply for a
/// thread no longer shown is dropped.
#[derive(Clone, Debug, PartialEq)]
pub enum Then {
    Link {
        generation: u64,
    },
    Unlink {
        number: i64,
    },
    List {
        generation: u64,
    },
    /// One of a refresh's reads; `round` tells its failure once.
    Invalidate {
        generation: u64,
        round: u64,
    },
}

/// What the pull requests ask of their owner, in order.
#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    /// An RPC where the thread's environment is served.
    Call {
        environment: String,
        method: &'static str,
        payload: Json,
        then: Then,
    },
    /// An orchestration command there.
    Dispatch {
        environment: String,
        command: Json,
        then: Then,
    },
    /// An error toast.
    Notify { title: String, description: String },
    /// A page for the user's browser.
    Open(String),
    /// Text for the clipboard.
    Copy(String),
}

/// What changed besides the rows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Note {
    Count,
    /// The rows' content: openCount.
    Rows,
    /// online, problem, notice, linking, refreshing, linkOpen.
    State,
    /// projectOpen, projectProblem.
    Project,
}

/// What the store says of the thread shown.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Shown {
    /// The thread row's `pullRequests`.
    pub links: Vec<Json>,
    pub online: bool,
    pub notice: String,
    pub project_id: String,
}

/// A thread's linked pull requests and its project's open ones.
#[derive(Debug, Default)]
pub struct PullRequests {
    /// `environment:threadId`.
    thread: String,
    project_id: String,
    links: Vec<Json>,
    online: bool,
    notice: String,
    problem: String,
    link_open: bool,
    linking: bool,
    refreshing: usize,
    project: Vec<Json>,
    /// The thread whose project list is read, or being read.
    project_thread: String,
    project_problem: String,
    generation: u64,
    round: u64,
    told: u64,
    changes: Vec<RowChange>,
    notes: Vec<Note>,
    effects: Vec<Effect>,
}

impl PullRequests {
    pub fn new() -> PullRequests {
        PullRequests::default()
    }

    pub fn environment(&self) -> &str {
        self.thread.split_once(':').map_or("", |(e, _)| e)
    }

    pub fn thread_id(&self) -> &str {
        self.thread.split_once(':').map_or("", |(_, t)| t)
    }

    pub fn thread(&self) -> &str {
        &self.thread
    }

    /// Points it at `thread_key` (empty: none) as the store has it now.
    /// Another thread starts over: what was asked for the last one is
    /// dropped as it answers.
    pub fn set_thread(&mut self, thread_key: &str, shown: Shown) {
        if thread_key != self.thread {
            self.thread = thread_key.to_owned();
            self.generation += 1;
            self.project.clear();
            self.project_thread.clear();
            self.project_problem.clear();
            self.notes.push(Note::Project);
            self.problem.clear();
            self.link_open = false;
            // desktop-qt kept these for the thread left, so a link or a
            // refresh in flight then stayed in flight on the next thread.
            self.linking = false;
            self.refreshing = 0;
            self.notes.push(Note::State);
        }
        self.project_id = shown.project_id;
        if shown.online != self.online || shown.notice != self.notice {
            self.online = shown.online;
            self.notice = shown.notice;
            self.notes.push(Note::State);
        }
        let links: Vec<Json> = shown
            .links
            .into_iter()
            .filter(|link| text(link, "source") != "stack-dismissed")
            .collect();
        if links == self.links {
            return;
        }
        let same_rows = links.len() == self.links.len()
            && links
                .iter()
                .zip(&self.links)
                .all(|(a, b)| key_of(a) == key_of(b));
        self.links = links;
        if same_rows {
            // The same pull requests, newly synced: rows change in place.
            self.changes.push(RowChange::Changed {
                first: 0,
                count: self.links.len(),
                roles: &[],
            });
        } else {
            self.changes
                .push(RowChange::Reset(self.links.iter().map(row_key).collect()));
            self.notes.push(Note::Count);
            // A linked one leaves the project's list, an unlinked one
            // returns to it.
            self.notes.push(Note::Project);
        }
        self.notes.push(Note::Rows);
    }

    pub fn count(&self) -> usize {
        self.links.len()
    }

    /// The linked ones still open, or not synced yet.
    pub fn open_count(&self) -> usize {
        self.links
            .iter()
            .filter(|link| {
                let snapshot = snapshot_of(link);
                !snapshot.is_object() || text(snapshot, "state") == "open"
            })
            .count()
    }

    pub fn keys(&self) -> Vec<String> {
        self.links.iter().map(key_of).collect()
    }

    /// The row's state (`shown(link, "state")`).
    pub fn state(&self, row: usize) -> String {
        match self.links.get(row).map(|link| shown(link, "state")) {
            Some(Value::String(s)) => s.to_string(),
            _ => String::new(),
        }
    }

    pub fn index_of(&self, key: &str) -> Option<usize> {
        self.links.iter().position(|link| key_of(link) == key)
    }

    fn find(&self, key: &str) -> Option<&Json> {
        self.index_of(key).map(|row| &self.links[row])
    }

    pub fn online(&self) -> bool {
        self.online
    }

    pub fn notice(&self) -> &str {
        &self.notice
    }

    pub fn problem(&self) -> &str {
        &self.problem
    }

    pub fn linking(&self) -> bool {
        self.linking
    }

    pub fn refreshing(&self) -> bool {
        self.refreshing > 0
    }

    pub fn link_open(&self) -> bool {
        self.link_open
    }

    pub fn project_problem(&self) -> &str {
        &self.project_problem
    }

    /// Opens or closes the link field; either way an old problem goes.
    pub fn set_link_open(&mut self, open: bool) {
        if open == self.link_open && (open || self.problem.is_empty()) {
            return;
        }
        self.link_open = open;
        self.problem.clear();
        self.notes.push(Note::State);
    }

    fn set_problem(&mut self, problem: String) {
        if problem != self.problem {
            self.problem = problem;
            self.notes.push(Note::State);
        }
    }

    /// The project's open pull requests that are not linked:
    /// `[{key, number, title, author, branches, draft, url}]`.
    pub fn project_open(&self) -> Vec<Json> {
        self.project
            .iter()
            .filter_map(|entry| {
                let number = int_of(entry, "number", 0);
                let key = key_of(entry);
                // The linked ones are the rows above.
                if self.find(&key).is_some() {
                    return None;
                }
                Some(json!({
                    "key": key,
                    "number": number,
                    "title": text(entry, "title"),
                    "author": entry.get("author").map_or("", |a| text(a, "login")),
                    "branches": format!("{} → {}", text(entry, "headBranch"), text(entry, "baseBranch")),
                    "draft": entry.get("isDraft").and_then(Json::as_bool).unwrap_or(false),
                    "url": text(entry, "url"),
                }))
            })
            .collect()
    }

    /// Links what `input` names to the thread.
    pub fn link(&mut self, input: &str, repositories: &Repositories) {
        if self.thread.is_empty() || self.linking || !self.online {
            return;
        }
        let target = match resolve(input, repositories) {
            Ok(target) => target,
            Err(problem) => return self.set_problem(problem),
        };
        self.linking = true;
        self.problem.clear();
        self.notes.push(Note::State);
        self.effects.push(Effect::Dispatch {
            environment: self.environment().to_owned(),
            command: json!({
                "type": "thread.pull-request.link",
                "threadId": self.thread_id(),
                "host": target.host,
                "repository": target.repository,
                "number": target.number,
                "url": target.url,
                "source": "manual",
            }),
            then: Then::Link {
                generation: self.generation,
            },
        });
    }

    pub fn unlink(&mut self, key: &str) {
        let Some(link) = self.find(key).filter(|_| self.online) else {
            return;
        };
        let number = int_of(link, "number", 0);
        let command = json!({
            "type": "thread.pull-request.unlink",
            "threadId": self.thread_id(),
            "host": link.get("host").cloned().unwrap_or(Json::Null),
            "repository": link.get("repository").cloned().unwrap_or(Json::Null),
            "number": number,
        });
        self.effects.push(Effect::Dispatch {
            environment: self.environment().to_owned(),
            command,
            then: Then::Unlink { number },
        });
    }

    /// Reads the project's open pull requests, once per thread unless
    /// `again`.
    pub fn load_project(&mut self, again: bool) {
        if self.thread.is_empty() || !self.online || (!again && self.project_thread == self.thread)
        {
            return;
        }
        self.project_thread = self.thread.clone();
        self.effects.push(Effect::Call {
            environment: self.environment().to_owned(),
            method: "pullRequests.list",
            payload: json!({
                "state": "open",
                "involvement": "all",
                "projectId": self.project_id,
                "limit": 50,
            }),
            then: Then::List {
                generation: self.generation,
            },
        });
    }

    /// Reads the project's list and every linked pull request again.
    pub fn refresh(&mut self) {
        self.load_project(true);
        if self.links.is_empty() || self.refreshing > 0 || !self.online {
            return;
        }
        self.refreshing = self.links.len();
        self.round += 1;
        self.notes.push(Note::State);
        for link in &self.links {
            let reference = json!({
                "host": link.get("host").cloned().unwrap_or(Json::Null),
                "repository": link.get("repository").cloned().unwrap_or(Json::Null),
                "number": link.get("number").cloned().unwrap_or(Json::Null),
            });
            self.effects.push(Effect::Call {
                environment: self.environment().to_owned(),
                method: "pullRequests.invalidate",
                payload: json!({"reference": reference}),
                then: Then::Invalidate {
                    generation: self.generation,
                    round: self.round,
                },
            });
        }
    }

    pub fn open(&mut self, key: &str) {
        if let Some(link) = self.find(key) {
            self.effects
                .push(Effect::Open(text(link, "url").to_owned()));
        }
    }

    pub fn copy_link(&mut self, key: &str) {
        if let Some(link) = self.find(key) {
            self.effects
                .push(Effect::Copy(text(link, "url").to_owned()));
        }
    }

    /// The MC answered what `then` asked.
    pub fn answer(&mut self, then: Then, result: Result<Json, String>) {
        match then {
            Then::Link { generation } => {
                if generation != self.generation {
                    return;
                }
                self.linking = false;
                match result {
                    Err(e) => self.problem = format!("Could not link the pull request: {e}"),
                    Ok(_) => self.link_open = false,
                }
                self.notes.push(Note::State);
            }
            Then::Unlink { number } => {
                if let Err(e) = result {
                    self.effects.push(Effect::Notify {
                        title: format!("Could not unlink pull request #{number}"),
                        description: e,
                    });
                }
            }
            Then::List { generation } => {
                if generation != self.generation {
                    return;
                }
                let (entries, problem) = match result {
                    Ok(result) => (
                        result
                            .get("entries")
                            .and_then(Json::as_array)
                            .cloned()
                            .unwrap_or_default(),
                        String::new(),
                    ),
                    Err(e) => {
                        // A read that failed is tried again the next time
                        // the tab asks.
                        self.project_thread.clear();
                        (Vec::new(), e)
                    }
                };
                self.project = entries.into_iter().filter(Json::is_object).collect();
                self.project_problem = problem;
                self.notes.push(Note::Project);
            }
            Then::Invalidate { generation, round } => {
                // One failure is told once, however many pull requests it
                // stopped.
                if let Err(e) = result
                    && self.told < round
                {
                    self.told = round;
                    self.effects.push(Effect::Notify {
                        title: "Could not refresh pull requests".into(),
                        description: e,
                    });
                }
                if generation != self.generation || round != self.round || self.refreshing == 0 {
                    return;
                }
                self.refreshing -= 1;
                if self.refreshing == 0 {
                    self.notes.push(Note::State);
                }
            }
        }
    }

    pub fn take_effects(&mut self) -> Vec<Effect> {
        std::mem::take(&mut self.effects)
    }

    pub fn take_notes(&mut self) -> Vec<Note> {
        std::mem::take(&mut self.notes)
    }
}

impl RowSource for PullRequests {
    fn roles(&self) -> &'static [&'static str] {
        ROLES
    }

    fn row_count(&self) -> usize {
        self.links.len()
    }

    fn row_key(&self, row: usize) -> RowKey {
        self.links.get(row).map_or(row as RowKey, row_key)
    }

    fn data(&self, row: usize, role: &str) -> Value {
        self.links
            .get(row)
            .map_or(Value::Undefined, |link| shown(link, role))
    }

    fn take_changes(&mut self) -> Vec<RowChange> {
        std::mem::take(&mut self.changes)
    }
}

/// A toast: type, title, description.
pub type Notify = Rc<dyn Fn(&Engine, &str, &str, &str)>;
/// A page for the user's browser, or text for the clipboard.
pub type Hand = Rc<dyn Fn(&Engine, &str)>;

struct Inner {
    rows: Rc<ListRows<PullRequests>>,
    mc: Rc<dyn Mc>,
    notify: Notify,
    open: Hand,
    copy: Hand,
}

impl std::fmt::Debug for Inner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ThreadPullRequests")
            .field("rows", &self.rows)
            .finish_non_exhaustive()
    }
}

/// A thread's linked pull requests: the Pull requests tab.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "ThreadPullRequests", uncreatable)]
pub struct ThreadPullRequests {
    #[qml(readonly, notify)]
    count: i32,
    /// The linked ones still open (or not synced yet).
    #[qml(readonly, notify)]
    open_count: i32,
    /// Whether the thread's environment is online: nothing is asked of it
    /// otherwise.
    #[qml(readonly, notify)]
    online: bool,
    /// Why the last link failed.
    #[qml(readonly, notify)]
    problem: Atom,
    /// Why the list may be short: an MC that keeps no branch pull requests.
    #[qml(readonly, notify)]
    notice: Atom,
    #[qml(readonly, notify)]
    linking: bool,
    #[qml(readonly, notify)]
    refreshing: bool,
    /// Whether the link field shows; QML opens and closes it.
    #[qml(notify)]
    link_open: bool,
    /// The project's open pull requests that are not linked:
    /// [{key, number, title, author, branches, draft, url}].
    #[qml(readonly, notify)]
    project_open: Value,
    #[qml(readonly, notify)]
    project_problem: Atom,
    #[qml(skip)]
    inner: Rc<Inner>,
}

fn inner_of(engine: &Engine, obj: ObjectId) -> Option<Rc<Inner>> {
    engine
        .with::<ThreadPullRequests, _>(obj, |p| p.inner.clone())
        .ok()
}

impl ThreadPullRequests {
    /// The pull requests owned by `owner`, asking `mc`; `notify` raises a
    /// toast, `open` hands a page to the browser and `copy` text to the
    /// clipboard.
    pub fn create(
        engine: &Engine,
        owner: Option<ObjectId>,
        mc: Rc<dyn Mc>,
        notify: impl Fn(&Engine, &str, &str, &str) + 'static,
        open: impl Fn(&Engine, &str) + 'static,
        copy: impl Fn(&Engine, &str) + 'static,
    ) -> Result<ObjectId, EngineError> {
        let rows = ListRows::new(PullRequests::new());
        let inner = Rc::new(Inner {
            rows: rows.clone(),
            mc,
            notify: Rc::new(notify),
            open: Rc::new(open),
            copy: Rc::new(copy),
        });
        let object = ThreadPullRequests {
            count: 0,
            open_count: 0,
            online: false,
            problem: Atom::new(""),
            notice: Atom::new(""),
            linking: false,
            refreshing: false,
            link_open: false,
            project_open: Value::Undefined,
            project_problem: Atom::new(""),
            inner,
        };
        let obj = engine.create_native(object, owner)?;
        rows.attach(engine, obj)?;
        // QML opens and closes the link field; the core follows.
        engine.connect_by_name(obj, "linkOpenChanged", move |engine, _| {
            if let Ok(open) = engine.get(obj, ThreadPullRequests::LINK_OPEN) {
                ThreadPullRequests::update(engine, obj, |p| p.set_link_open(open));
            }
        })?;
        tell(engine, obj, &rows, &[Note::Project]);
        Ok(obj)
    }

    /// Points `obj` at `thread_key` (empty: none) as the store has it now;
    /// the right panel calls it whenever the thread shown or the store
    /// changes.
    pub fn set_thread(engine: &Engine, obj: ObjectId, thread_key: &str) {
        let environment = thread_key.split_once(':').map_or("", |(e, _)| e);
        let shown = store::with(engine, |s| {
            let row = s.thread_row(thread_key);
            // Only a known environment that keeps no branch pull requests
            // is told to update.
            let known = !thread_key.is_empty() && !s.environment(environment).is_empty();
            let notice = if known && !s.supports(environment, "threadPullRequests") {
                "Update this environment's server to see branch pull requests."
            } else {
                ""
            };
            Shown {
                links: row
                    .and_then(|r| r.get("pullRequests"))
                    .and_then(Json::as_array)
                    .cloned()
                    .unwrap_or_default()
                    .into_iter()
                    .filter(Json::is_object)
                    .collect(),
                online: s.environment_online(environment),
                notice: notice.to_owned(),
                project_id: row
                    .and_then(|r| r.get("projectId"))
                    .and_then(Json::as_str)
                    .unwrap_or("")
                    .to_owned(),
            }
        });
        ThreadPullRequests::update(engine, obj, |p| p.set_thread(thread_key, shown));
    }

    /// Links what `input` names to the thread shown.
    pub fn link(engine: &Engine, obj: ObjectId, input: &str) {
        let Some((environment, project_id)) = ThreadPullRequests::read(engine, obj, |p| {
            (p.environment().to_owned(), p.project_id.clone())
        }) else {
            return;
        };
        let repositories = store::with(engine, |s| Repositories {
            readable: s
                .project_rows(&environment)
                .into_iter()
                .map(repository_of)
                .collect(),
            own: s
                .project_row(&environment, &project_id)
                .map(repository_of)
                .unwrap_or_default(),
        });
        ThreadPullRequests::update(engine, obj, |p| p.link(input, &repositories));
    }

    /// Runs `f` on the pull requests of `obj`, then tells the views and the
    /// properties what it changed and asks the MC what it said to. None when
    /// `obj` is not live.
    pub fn update<R>(
        engine: &Engine,
        obj: ObjectId,
        f: impl FnOnce(&mut PullRequests) -> R,
    ) -> Option<R> {
        let inner = inner_of(engine, obj)?;
        let (result, notes, effects) = inner.rows.update(engine, |p| {
            let result = f(p);
            (result, p.take_notes(), p.take_effects())
        });
        tell(engine, obj, &inner.rows, &notes);
        for effect in effects {
            run(engine, obj, &inner, effect);
        }
        Some(result)
    }

    /// Reads the pull requests of `obj`. `f` must not call back into them.
    pub fn read<R>(
        engine: &Engine,
        obj: ObjectId,
        f: impl FnOnce(&PullRequests) -> R,
    ) -> Option<R> {
        Some(inner_of(engine, obj)?.rows.read(f))
    }
}

fn tell(engine: &Engine, obj: ObjectId, rows: &ListRows<PullRequests>, notes: &[Note]) {
    let mut result = Ok(());
    let mut told = Vec::new();
    for note in notes {
        if told.contains(note) {
            continue;
        }
        told.push(*note);
        result = result.and_then(|()| match note {
            Note::Count => {
                let count = rows.read(|p| int(p.count()));
                engine.set_internal(obj, ThreadPullRequests::COUNT, count)
            }
            Note::Rows => {
                let open = rows.read(|p| int(p.open_count()));
                engine.set_internal(obj, ThreadPullRequests::OPEN_COUNT, open)
            }
            Note::State => {
                let (online, problem, notice, linking, refreshing, open) = rows.read(|p| {
                    (
                        p.online(),
                        Atom::new(p.problem()),
                        Atom::new(p.notice()),
                        p.linking(),
                        p.refreshing(),
                        p.link_open(),
                    )
                });
                engine
                    .set_internal(obj, ThreadPullRequests::ONLINE, online)
                    .and_then(|()| engine.set_internal(obj, ThreadPullRequests::PROBLEM, problem))
                    .and_then(|()| engine.set_internal(obj, ThreadPullRequests::NOTICE, notice))
                    .and_then(|()| engine.set_internal(obj, ThreadPullRequests::LINKING, linking))
                    .and_then(|()| {
                        engine.set_internal(obj, ThreadPullRequests::REFRESHING, refreshing)
                    })
                    .and_then(|()| engine.set_internal(obj, ThreadPullRequests::LINK_OPEN, open))
            }
            Note::Project => {
                let (open, problem) =
                    rows.read(|p| (p.project_open(), Atom::new(p.project_problem())));
                let open = Json::Array(open).to_value();
                engine
                    .set_internal(obj, ThreadPullRequests::PROJECT_OPEN, open)
                    .and_then(|()| {
                        engine.set_internal(obj, ThreadPullRequests::PROJECT_PROBLEM, problem)
                    })
            }
        });
    }
    if let Err(e) = result {
        engine.log(
            ljos::prelude::LogLevel::Warning,
            "ThreadPullRequests",
            e.to_string(),
        );
    }
}

fn run(engine: &Engine, obj: ObjectId, inner: &Inner, effect: Effect) {
    let answer = move |then: Then| -> crate::mc::Reply {
        Box::new(move |engine, result: Result<Json, McError>| {
            let result = result.map_err(|e| e.message);
            ThreadPullRequests::update(engine, obj, |p| p.answer(then, result));
        })
    };
    match effect {
        Effect::Call {
            environment,
            method,
            payload,
            then,
        } => inner.mc.call(&environment, method, payload, answer(then)),
        Effect::Dispatch {
            environment,
            command,
            then,
        } => inner
            .mc
            .dispatch_command(&environment, command, answer(then)),
        Effect::Notify { title, description } => {
            (inner.notify)(engine, "error", &title, &description);
        }
        Effect::Open(url) => (inner.open)(engine, &url),
        Effect::Copy(url) => (inner.copy)(engine, &url),
    }
}

#[qml_impl]
impl ThreadPullRequests {
    /// The row of the linked pull request `key` (`host/repository#number`),
    /// or -1.
    #[qml(invokable)]
    fn index_of(cx: &Cx, key: Atom) -> i32 {
        ThreadPullRequests::read(cx.engine, cx.this, |p| p.index_of(&key))
            .flatten()
            .map_or(-1, int)
    }

    /// Links a pull request URL, or `123` / `#123` of the thread's own
    /// repository.
    #[qml(invokable, name = "link")]
    fn link_text(cx: &Cx, text: Atom) {
        ThreadPullRequests::link(cx.engine, cx.this, &text);
    }

    #[qml(invokable)]
    fn unlink(cx: &Cx, key: Atom) {
        ThreadPullRequests::update(cx.engine, cx.this, |p| p.unlink(&key));
    }

    #[qml(invokable)]
    fn refresh(cx: &Cx) {
        ThreadPullRequests::update(cx.engine, cx.this, PullRequests::refresh);
    }

    /// Reads the project's open pull requests, once per thread unless
    /// `again` (QML may leave it out).
    #[qml(invokable)]
    fn load_project(cx: &Cx, again: Option<bool>) {
        let again = again.unwrap_or(false);
        ThreadPullRequests::update(cx.engine, cx.this, |p| p.load_project(again));
    }

    #[qml(invokable)]
    fn open(cx: &Cx, key: Atom) {
        ThreadPullRequests::update(cx.engine, cx.this, |p| p.open(&key));
    }

    #[qml(invokable)]
    fn copy_link(cx: &Cx, key: Atom) {
        ThreadPullRequests::update(cx.engine, cx.this, |p| p.copy_link(&key));
    }
}

#[cfg(test)]
#[path = "pull_requests_tests.rs"]
mod tests;
