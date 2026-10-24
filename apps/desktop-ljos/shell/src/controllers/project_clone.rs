//! `projectClones`, desktop-qt's ProjectCloneController: cloning a
//! repository into a new project.
//!
//! Add project's sources (`projects`) list "Git URL" and each hosting
//! provider's repository, ready ones first ([`sources`]); whether a provider
//! is ready comes from `server.discoverSourceControl`, and one that is not
//! ("Setup Required") opens the Source Control settings instead. Choosing a
//! ready source asks for the repository in the palette (a provider's is
//! looked up, `sourceControl.lookupRepository`), then browses for where it
//! goes with the repository's folder name pinned to the path, in the folder
//! Add project browses from ([`projects::browse_start`]). Enter there
//! starts the clone (`projectClone.start`): the MC adds the project at once
//! and clones in the background, and the new project's draft opens.
//!
//! Every clone the MC reports (the `projectClones` shape of each online
//! environment of the cluster) has one toast, changed in place as git moves
//! on: running (Cancel), done (Open project), failed or cancelled (Retry,
//! Remove project).
//!
//! The palette steps ([`ask_repository`], [`submit_repository`],
//! [`ask_destination`], [`start`]) are the functions the palette calls back.

use std::collections::{HashMap, HashSet};
use std::sync::LazyLock;

use chrono::{TimeZone, Utc};
use ljos::prelude::Engine;
use regex::Regex;
use serde_json::json;

use crate::commands::Choice;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::drafts;
use crate::controllers::navigation::{self, Navigation, Route};
use crate::controllers::palette;
use crate::controllers::projects;
use crate::controllers::sidebar;
use crate::controllers::toasts::{Action, Toasts};
use crate::json::Json;
use crate::mc::{Mc, SubId};
use crate::sidebar_model as model;
use crate::store;
use crate::thread_view::summary::plain_detail;

const SOURCE_CONTROL_SECTION: &str = "/settings/source-control";
/// A finished clone's toast stays this long.
const DONE_TOAST_MS: i64 = 8000;

fn regex(pattern: &str) -> Regex {
    Regex::new(pattern).expect("a valid pattern")
}

/// The owner/repo shorthand taken as a public GitHub repository.
static GITHUB_SHORTHAND: LazyLock<Regex> =
    LazyLock::new(|| regex(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]+(?:\.git)?$"));
static SSH_ADDRESS: LazyLock<Regex> = LazyLock::new(|| regex(r"^[^/\\:]+@[^/\\:]+:"));
static WINDOWS_PATH: LazyLock<Regex> = LazyLock::new(|| regex(r"^(?:[A-Za-z]:[\\/]|\\\\)"));

/// Where a clone comes from: "url" or a provider kind.
#[derive(Clone, Copy)]
struct Source {
    kind: &'static str,
    label: &'static str,
    hint: &'static str,
}

const URL: Source = Source {
    kind: "url",
    label: "Git URL",
    hint: "URL",
};

const PROVIDERS: [Source; 5] = [
    Source {
        kind: "github",
        label: "GitHub",
        hint: "owner/repo",
    },
    Source {
        kind: "gitlab",
        label: "GitLab",
        hint: "group/project",
    },
    Source {
        kind: "forgejo",
        label: "Forgejo / Gitea",
        hint: "owner/repo",
    },
    Source {
        kind: "bitbucket",
        label: "Bitbucket",
        hint: "workspace/repository",
    },
    Source {
        kind: "azure-devops",
        label: "Azure DevOps",
        hint: "project/repository",
    },
];

/// What the user chose to clone, once its address is known.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Chosen {
    pub environment_id: String,
    pub remote_url: String,
    pub directory_name: String,
}

/// An `owner/repo` is the public GitHub repository of that name; anything
/// else is the address as typed, trimmed.
pub fn normalize_pasted_url(input: &str) -> String {
    let trimmed = input.trim();
    if !GITHUB_SHORTHAND.is_match(trimmed) {
        return trimmed.to_owned();
    }
    let git = if trimmed.ends_with(".git") {
        ""
    } else {
        ".git"
    };
    format!("https://github.com/{trimmed}{git}")
}

/// The folder `git clone` would pick: the last segment of an owner/repo or
/// any form of remote URL, minus ".git"; empty for a URL that stops at its
/// host or port.
pub fn directory_name(repository_or_url: &str) -> String {
    let bare = repository_or_url
        .split(['?', '#'])
        .next()
        .unwrap_or_default()
        .trim();
    let scheme = bare.find("://");
    let has_host = scheme.is_some() || SSH_ADDRESS.is_match(bare);
    let path = scheme.map_or(bare, |at| &bare[at + 3..]);
    let segments: Vec<&str> = path
        .split(['/', '\\', ':'])
        .filter(|s| !s.trim().is_empty())
        .collect();
    if has_host && segments.len() < 2 {
        return String::new();
    }
    let last = segments.last().map_or("", |s| s.trim());
    if has_host
        && segments.len() == 2
        && !last.is_empty()
        && last.bytes().all(|b| b.is_ascii_digit())
    {
        return String::new();
    }
    last.strip_suffix(".git").unwrap_or(last).to_owned()
}

/// `directory` with the repository's folder name under it.
pub fn destination_path(directory: &str, name: &str) -> String {
    if name.trim().is_empty() {
        return directory.to_owned();
    }
    let separator = if directory.ends_with('/') || directory.ends_with('\\') {
        ""
    } else {
        "/"
    };
    format!("{directory}{separator}{}", name.trim())
}

/// A path without its `.` and `..` segments, as QDir::cleanPath.
fn clean_path(path: &str) -> String {
    let absolute = path.starts_with('/');
    let mut kept: Vec<&str> = Vec::new();
    for segment in path.split('/') {
        match segment {
            "" | "." => {}
            ".." => {
                if kept.last().is_some_and(|last| *last != "..") {
                    kept.pop();
                } else if !absolute {
                    kept.push("..");
                }
            }
            segment => kept.push(segment),
        }
    }
    match (absolute, kept.is_empty()) {
        (true, _) => format!("/{}", kept.join("/")),
        (false, true) => ".".into(),
        (false, false) => kept.join("/"),
    }
}

fn text(value: &Json, key: &str) -> String {
    value
        .get(key)
        .and_then(Json::as_str)
        .unwrap_or_default()
        .to_owned()
}

fn option_value(option: Option<&Json>) -> String {
    match option {
        Some(o) if o.get("_tag").and_then(Json::as_str) == Some("Some") => text(o, "value"),
        _ => String::new(),
    }
}

/// What a clone is called: its repository, else its folder.
fn display_name(clone: &Json) -> String {
    let name = text(&clone["repository"], "nameWithOwner");
    if !name.is_empty() {
        return name;
    }
    let destination = text(clone, "destinationPath");
    destination
        .split(['/', '\\'])
        .rfind(|s| !s.is_empty())
        .unwrap_or(&destination)
        .to_owned()
}

fn progress_summary(clone: &Json) -> String {
    let label = match text(clone, "stage").as_str() {
        "connecting" => "Connecting",
        "counting" => "Counting objects",
        "receiving" => "Receiving objects",
        "resolving" => "Resolving deltas",
        "checkout" => "Checking out files",
        _ => "",
    };
    let mut parts = vec![label.to_owned()];
    if let Some(percent) = clone.get("percent").and_then(Json::as_f64) {
        parts.push(format!("{}%", percent as i64));
    }
    let detail = text(clone, "detail");
    if !detail.is_empty() {
        parts.push(detail);
    }
    parts.retain(|p| !p.is_empty());
    parts.join(" · ")
}

/// A clone's state in the one string that tells whether its toast needs to
/// change.
fn shown_of(clone: &Json) -> String {
    let percent = match clone.get("percent") {
        Some(Json::Number(n)) => n.to_string(),
        Some(Json::String(s)) => s.clone(),
        _ => String::new(),
    };
    [
        text(clone, "phase"),
        text(clone, "stage"),
        percent,
        text(clone, "detail"),
        text(clone, "error"),
    ]
    .join(":")
}

/// A clone's toast and what it last showed.
#[derive(Clone)]
struct Tracked {
    toast_id: String,
    shown: String,
    phase: String,
}

#[derive(Default)]
struct Discovery {
    result: Option<Json>,
    asking: bool,
}

/// How a clone's toast reads: kind, title, description, actions, time.
struct Reading {
    kind: &'static str,
    title: String,
    description: String,
    actions: Vec<Action>,
    timeout_ms: i64,
}

pub struct ProjectClone {
    me: Me<ProjectClone>,
    mc: std::rc::Rc<dyn Mc>,
    active: bool,
    discovery: HashMap<String, Discovery>,
    /// A lookup or a start on its way, which Enter does not repeat.
    busy: bool,
    lookup: u64,
    /// A project whose clone started and whose row has not reached the shell
    /// yet; its draft opens when the row does.
    started: Option<(String, String)>,
    /// The `projectClones` subscription of each online environment.
    subscriptions: HashMap<String, SubId>,
    /// Toasts by environment, then project id.
    toasts: HashMap<String, HashMap<String, Tracked>>,
}

impl Controller for ProjectClone {
    fn new(init: Init<'_, Self>) -> Self {
        ProjectClone {
            me: init.me,
            mc: init.mc,
            active: false,
            discovery: HashMap::new(),
            busy: false,
            lookup: 0,
            started: None,
            subscriptions: HashMap::new(),
            toasts: HashMap::new(),
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let me = self.me.clone();
        store::on_changed(engine, move |engine| {
            me.run(engine, |c, engine| c.store_changed(engine));
        });
        self.follow(engine);
    }
}

impl ProjectClone {
    fn store_changed(&mut self, engine: &Engine) {
        if !self.active {
            return;
        }
        self.follow(engine);
        if let Some((environment_id, project_id)) = &self.started
            && store::with(engine, |s| {
                s.project(&format!("{environment_id}:{project_id}"))
            })
            .is_some()
        {
            let (environment_id, project_id) = (environment_id.clone(), project_id.clone());
            self.started = None;
            open_project(engine, &environment_id, &project_id);
        }
    }

    /// Add project's clone sources on `environment_id`, after Local folder.
    pub fn sources(&mut self, engine: &Engine, environment_id: &str) -> Vec<Choice> {
        // Asked again each time they are shown; a new answer refreshes them.
        self.discover(engine, environment_id);
        // Git URL, then the providers ready first, each part by label.
        let mut providers = PROVIDERS;
        providers.sort_by(|a, b| {
            let ready = |p: &Source| self.readiness(environment_id, p.kind).0;
            ready(b)
                .cmp(&ready(a))
                .then_with(|| model::locale_compare(a.label, b.label))
        });
        std::iter::once(URL)
            .chain(providers)
            .map(|source| self.choice(environment_id, source))
            .collect()
    }

    fn choice(&self, environment_id: &str, source: Source) -> Choice {
        let url = source.kind == URL.kind;
        let title = if url {
            "Git URL".to_owned()
        } else {
            format!("{} repository", source.label)
        };
        let environment = environment_id.to_owned();
        let mut choice = Choice::new(&format!("clone-{}", source.kind), &title, |_| {});
        choice.run = None;
        choice.description = if url {
            "Clone from a remote URL".into()
        } else {
            format!("Clone {} {}", source.label, source.hint)
        };
        choice.terms = ["clone", "remote", "repository", "repo", "git", source.label]
            .map(String::from)
            .to_vec();
        let (ready, hint) = self.readiness(environment_id, source.kind);
        if ready {
            choice.keep_open = true;
            choice.run = Some(std::rc::Rc::new(move |engine| {
                ask_repository(engine, &environment, source);
            }));
        } else {
            // The web disables it and offers its Setup Required button, which
            // opens the settings; here choosing the row is pressing that
            // button.
            let reason = if hint.is_empty() {
                "Open Settings -> Source Control to configure this provider.".to_owned()
            } else {
                plain_detail(&hint)
            };
            choice.description = format!("Setup Required · {reason}");
            choice.terms.push("setup required".into());
            choice.run = Some(std::rc::Rc::new(|engine| {
                controller::with::<Navigation, _>(engine, |n, e| {
                    n.open(e, Route::Settings(SOURCE_CONTROL_SECTION.into()));
                });
            }));
        }
        choice
    }

    /// Whether the source can be cloned from, and if not what to do about it.
    fn readiness(&self, environment_id: &str, kind: &str) -> (bool, String) {
        if kind == URL.kind {
            return (true, String::new());
        }
        let unavailable = (
            false,
            "Provider status unavailable. Open Settings -> Source Control and rescan.".to_owned(),
        );
        let Some(discovery) = self
            .discovery
            .get(environment_id)
            .and_then(|d| d.result.as_ref())
        else {
            return unavailable;
        };
        let providers = discovery
            .get("sourceControlProviders")
            .and_then(Json::as_array)
            .map(Vec::as_slice)
            .unwrap_or_default();
        let Some(provider) = providers.iter().find(|p| text(p, "kind") == kind) else {
            return unavailable;
        };
        if text(provider, "status") != "available" {
            return (false, text(provider, "installHint"));
        }
        let auth = &provider["auth"];
        if text(auth, "status") == "unauthenticated" {
            let detail = option_value(auth.get("detail"));
            return (
                false,
                if detail.is_empty() {
                    format!(
                        "{} is not authenticated. Open Settings -> Source Control for setup guidance.",
                        text(provider, "label")
                    )
                } else {
                    detail
                },
            );
        }
        (true, String::new())
    }

    fn discover(&mut self, engine: &Engine, environment_id: &str) {
        let online = store::with(engine, |s| s.environment_online(environment_id));
        let discovery = self.discovery.entry(environment_id.to_owned()).or_default();
        if discovery.asking || !online {
            return;
        }
        discovery.asking = true;
        let me = self.me.clone();
        let environment = environment_id.to_owned();
        self.mc.call(
            environment_id,
            "server.discoverSourceControl",
            json!({}),
            Box::new(move |engine, result| {
                me.run(engine, |c, engine| {
                    let discovery = c.discovery.entry(environment).or_default();
                    discovery.asking = false;
                    // A failed scan keeps what the last one found.
                    let Ok(result) = result else { return };
                    if discovery.result.as_ref() == Some(&result) {
                        return;
                    }
                    discovery.result = Some(result);
                    // The open sources menu reads the new answer.
                    palette::refresh_menu(engine);
                });
            }),
        );
    }

    fn follow(&mut self, engine: &Engine) {
        let online: Vec<String> = store::with(engine, |s| {
            s.environments()
                .into_iter()
                .filter(|e| s.environment_online(e))
                .collect()
        });
        let gone: Vec<String> = self
            .subscriptions
            .keys()
            .filter(|e| !online.contains(e))
            .cloned()
            .collect();
        for environment_id in gone {
            if let Some(id) = self.subscriptions.remove(&environment_id) {
                // What it last reported stands until it is back.
                self.mc.unsubscribe(id);
            }
        }
        for environment_id in online {
            if self.subscriptions.contains_key(&environment_id) {
                continue;
            }
            let shape = json!({"type": "projectClones", "environment": environment_id});
            let me = self.me.clone();
            let environment = environment_id.clone();
            let id = self.mc.subscribe(
                shape,
                Box::new(move |engine, frame| {
                    if frame.get("t").and_then(Json::as_str) != Some("projectClones") {
                        return;
                    }
                    let clones = frame
                        .get("clones")
                        .and_then(Json::as_array)
                        .cloned()
                        .unwrap_or_default();
                    let environment = environment.clone();
                    me.run(engine, move |c, engine| {
                        c.reconcile(engine, &environment, &clones);
                    });
                }),
                None,
            );
            self.subscriptions.insert(environment_id, id);
        }
    }

    /// A toast per clone, changed in place.
    fn reconcile(&mut self, engine: &Engine, environment_id: &str, clones: &[Json]) {
        let mut seen = HashSet::new();
        for clone in clones {
            let project_id = text(clone, "projectId");
            let phase = text(clone, "phase");
            seen.insert(project_id.clone());
            let shown = shown_of(clone);
            let found = self
                .toasts
                .get(environment_id)
                .and_then(|t| t.get(&project_id))
                .cloned();
            if found.as_ref().is_some_and(|f| f.shown == shown) {
                continue;
            }
            let reading = reading_of(clone, environment_id, &project_id);
            let toast_id = controller::with::<Toasts, _>(engine, |toasts, engine| {
                if let Some(found) = &found
                    && toasts.replace(
                        engine,
                        &found.toast_id,
                        reading.kind,
                        &reading.title,
                        &reading.description,
                        reading.actions.clone(),
                        reading.timeout_ms,
                    )
                {
                    return found.toast_id.clone();
                }
                toasts.show_actions(
                    engine,
                    reading.kind,
                    &reading.title,
                    &reading.description,
                    reading.actions,
                    reading.timeout_ms,
                )
            })
            .unwrap_or_default();
            self.toasts
                .entry(environment_id.to_owned())
                .or_default()
                .insert(
                    project_id,
                    Tracked {
                        toast_id,
                        shown,
                        phase,
                    },
                );
        }
        // A clone the MC stopped reporting takes its toast, unless it
        // finished: that toast goes in its own time.
        let Some(tracked) = self.toasts.get_mut(environment_id) else {
            return;
        };
        let gone: Vec<String> = tracked
            .keys()
            .filter(|id| !seen.contains(*id))
            .cloned()
            .collect();
        for project_id in gone {
            if let Some(t) = tracked.remove(&project_id)
                && t.phase != "done"
            {
                controller::with::<Toasts, _>(engine, |toasts, engine| {
                    toasts.dismiss(engine, &t.toast_id);
                });
            }
        }
    }
}

/// The toast a clone in its phase shows.
fn reading_of(clone: &Json, environment_id: &str, project_id: &str) -> Reading {
    let name = display_name(clone);
    let destination = text(clone, "destinationPath");
    let phase = text(clone, "phase");
    let (environment, project) = (environment_id.to_owned(), project_id.to_owned());
    match phase.as_str() {
        "running" => Reading {
            kind: "loading",
            title: format!("Cloning {name}"),
            description: progress_summary(clone),
            actions: vec![
                Action::new("Cancel", move |engine| {
                    clone_action(
                        engine,
                        &environment,
                        "projectClone.cancel",
                        &project,
                        "Failed to cancel clone",
                    );
                })
                .keeping_toast(),
            ],
            timeout_ms: 0,
        },
        "done" => Reading {
            kind: "success",
            title: format!("Cloned {name}"),
            description: destination,
            actions: vec![Action::new("Open project", move |engine| {
                open_project(engine, &environment, &project);
            })],
            timeout_ms: DONE_TOAST_MS,
        },
        // Failed or cancelled: the project stays, pointing at an empty
        // folder.
        _ => {
            let cancelled = phase == "cancelled";
            let error = text(clone, "error");
            let retry = {
                let (environment, project) = (environment.clone(), project.clone());
                Action::new("Retry", move |engine| {
                    clone_action(
                        engine,
                        &environment,
                        "projectClone.retry",
                        &project,
                        "Failed to retry clone",
                    );
                })
                .keeping_toast()
            };
            Reading {
                kind: if cancelled { "info" } else { "error" },
                title: if cancelled {
                    format!("Cancelled cloning {name}")
                } else {
                    format!("Failed to clone {name}")
                },
                description: if cancelled {
                    destination
                } else if error.is_empty() {
                    "The clone failed.".into()
                } else {
                    error
                },
                // The MC drops the clone with its project, which takes the
                // toast.
                actions: vec![
                    retry,
                    Action::new("Remove project", move |engine| {
                        remove_project(engine, &environment, &project);
                    })
                    .keeping_toast(),
                ],
                timeout_ms: 0,
            }
        }
    }
}

/// Add project's clone sources on `environment_id`, after Local folder.
pub fn sources(engine: &Engine, environment_id: &str) -> Vec<Choice> {
    controller::with::<ProjectClone, _>(engine, |c, engine| c.sources(engine, environment_id))
        .unwrap_or_default()
}

fn toast_error(engine: &Engine, title: &str, reason: &str) {
    controller::with::<Toasts, _>(engine, |t, e| {
        t.error(e, title, reason);
    });
}

/// Asks the palette for the repository to clone.
fn ask_repository(engine: &Engine, environment_id: &str, source: Source) {
    controller::with::<ProjectClone, _>(engine, |c, _| {
        c.busy = false;
        c.lookup += 1;
    });
    let url = source.kind == URL.kind;
    let (title, placeholder, hint) = if url {
        (
            "Git URL".to_owned(),
            "Enter Git clone URL".to_owned(),
            "Enter a Git clone URL and press Enter to continue.",
        )
    } else {
        (
            format!("{} repository", source.label),
            format!("Enter {} repository ({})", source.label, source.hint),
            "Enter a repository path and press Enter to look it up.",
        )
    };
    let environment = environment_id.to_owned();
    let kind = source.kind;
    palette::ask(engine, &title, &placeholder, hint, move |engine, input| {
        submit_repository(engine, &environment, kind, input);
    });
}

/// A repository typed into the palette: a URL goes on to the destination, a
/// provider's is looked up first.
pub fn submit_repository(engine: &Engine, environment_id: &str, kind: &str, input: &str) {
    if !connected(engine, environment_id) {
        return;
    }
    let Some(lookup) = controller::with::<ProjectClone, _>(engine, |c, _| {
        if c.busy {
            return None;
        }
        if kind == URL.kind {
            return Some(None);
        }
        c.busy = true;
        c.lookup += 1;
        Some(Some(c.lookup))
    })
    .flatten() else {
        return;
    };
    let Some(lookup) = lookup else {
        ask_destination(
            engine,
            &Chosen {
                environment_id: environment_id.to_owned(),
                remote_url: normalize_pasted_url(input),
                directory_name: directory_name(input),
            },
        );
        return;
    };
    let Some(mc) = controller::mc(engine) else {
        return;
    };
    let environment = environment_id.to_owned();
    mc.call(
        environment_id,
        "sourceControl.lookupRepository",
        json!({"provider": kind, "repository": input}),
        Box::new(move |engine, result| {
            // The user moved on meanwhile.
            let current = controller::with::<ProjectClone, _>(engine, |c, _| {
                if c.lookup != lookup {
                    return false;
                }
                c.busy = false;
                true
            })
            .unwrap_or(false);
            if !current {
                return;
            }
            let repository = match result {
                Ok(repository) => repository,
                Err(error) => {
                    toast_error(engine, "Repository lookup failed", &error.message);
                    return;
                }
            };
            // GitHub and Forgejo clone over HTTPS; the others keep SSH.
            let https = matches!(text(&repository, "provider").as_str(), "github" | "forgejo");
            ask_destination(
                engine,
                &Chosen {
                    environment_id: environment,
                    remote_url: text(&repository, if https { "url" } else { "sshUrl" }),
                    directory_name: directory_name(&text(&repository, "nameWithOwner")),
                },
            );
        }),
    );
}

/// Asks the palette where the repository goes: browsing from where Add
/// project does, the folder name pinned to the path.
pub fn ask_destination(engine: &Engine, chosen: &Chosen) {
    let query = destination_path(
        &projects::browse_start(engine, &chosen.environment_id),
        &chosen.directory_name,
    );
    controller::with::<ProjectClone, _>(engine, |c, _| c.busy = false);
    let options = palette::BrowseOptions {
        query,
        pinned: chosen.directory_name.clone(),
        empty_text: "Choose a destination path and press Enter to clone.".into(),
        submit: "Clone".into(),
        keep_open: true,
    };
    let to = chosen.clone();
    palette::browse(
        engine,
        &chosen.environment_id,
        move |engine, path| start(engine, &to, path),
        options,
    );
}

/// Starts the clone into `input`, the destination the user typed.
pub fn start(engine: &Engine, chosen: &Chosen, input: &str) {
    if !connected(engine, &chosen.environment_id) {
        return;
    }
    if controller::with::<ProjectClone, _>(engine, |c, _| c.busy).unwrap_or(true) {
        return;
    }
    let mut destination = input.trim().to_owned();
    if destination.is_empty() {
        return;
    }
    let os = store::with(engine, |s| s.environment(&chosen.environment_id))
        .get("platform")
        .map(|p| text(p, "os"))
        .unwrap_or_default();
    if WINDOWS_PATH.is_match(&destination) && !os.starts_with("win") {
        toast_error(
            engine,
            "Clone failed",
            "Windows-style paths are only supported on Windows.",
        );
        return;
    }
    // A relative path is under the project the window shows.
    if destination == "."
        || destination == ".."
        || destination.starts_with("./")
        || destination.starts_with("../")
    {
        let root = match navigation::shown(engine) {
            Route::Thread(key) if key.starts_with(&format!("{}:", chosen.environment_id)) => {
                store::with(engine, |s| {
                    let project_id = s
                        .thread_row(&key)
                        .map(|row| {
                            row.get("projectId")
                                .and_then(Json::as_str)
                                .unwrap_or_default()
                                .to_owned()
                        })
                        .unwrap_or_default();
                    s.project_row(&chosen.environment_id, &project_id)
                        .and_then(|row| row.get("workspaceRoot"))
                        .and_then(Json::as_str)
                        .unwrap_or_default()
                        .to_owned()
                })
            }
            _ => String::new(),
        };
        if root.is_empty() {
            toast_error(
                engine,
                "Clone failed",
                "Relative paths require an active project.",
            );
            return;
        }
        destination = clean_path(&format!("{root}/{destination}"));
    }
    let title = destination
        .trim_end_matches(['/', '\\'])
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or_default()
        .to_owned();
    let Some(mc) = controller::mc(engine) else {
        return;
    };
    let project_id = hal_c2_mc::new_uuid();
    let created_at = Utc
        .timestamp_millis_opt(sidebar::now_ms(engine))
        .single()
        .unwrap_or_default();
    controller::with::<ProjectClone, _>(engine, |c, _| c.busy = true);
    let environment = chosen.environment_id.clone();
    let created = project_id.clone();
    mc.call(
        &chosen.environment_id,
        "projectClone.start",
        json!({
            "projectId": project_id,
            "title": title,
            "createdAt": model::format_iso(&created_at),
            "remoteUrl": chosen.remote_url,
            "destinationPath": destination,
        }),
        Box::new(move |engine, result| {
            controller::with::<ProjectClone, _>(engine, |c, _| c.busy = false);
            if let Err(error) = result {
                // The palette stays for another destination.
                toast_error(engine, "Clone failed", &error.message);
                return;
            }
            // The clone goes on in the background, in its toast.
            palette::finish(engine);
            if store::with(engine, |s| s.project(&format!("{environment}:{created}"))).is_some() {
                open_project(engine, &environment, &created);
            } else {
                controller::with::<ProjectClone, _>(engine, |c, _| {
                    c.started = Some((environment, created));
                });
            }
        }),
    );
}

/// False, with "Environment unavailable", when it is not connected.
fn connected(engine: &Engine, environment_id: &str) -> bool {
    if store::with(engine, |s| s.environment_online(environment_id)) {
        return true;
    }
    let label = text(
        &Json::Object(store::with(engine, |s| s.environment(environment_id))),
        "label",
    );
    let name = if label.is_empty() {
        "The selected environment"
    } else {
        &label
    };
    toast_error(
        engine,
        "Environment unavailable",
        &format!("{name} is not connected."),
    );
    false
}

fn open_project(engine: &Engine, environment_id: &str, project_id: &str) {
    if drafts::start(engine, environment_id, project_id).is_none() {
        toast_error(engine, "Failed to open project", "");
    }
}

/// The toast follows the MC's clone; a request that never got there says so.
fn clone_action(
    engine: &Engine,
    environment_id: &str,
    method: &str,
    project_id: &str,
    failure: &str,
) {
    let Some(mc) = controller::mc(engine) else {
        return;
    };
    let failure = failure.to_owned();
    mc.call(
        environment_id,
        method,
        json!({"projectId": project_id}),
        Box::new(move |engine, result| {
            if let Err(error) = result {
                toast_error(engine, &failure, &error.message);
            }
        }),
    );
}

/// Not forced, so a project that gained a thread meanwhile is refused rather
/// than lost.
fn remove_project(engine: &Engine, environment_id: &str, project_id: &str) {
    let Some(mc) = controller::mc(engine) else {
        return;
    };
    let (environment, project) = (environment_id.to_owned(), project_id.to_owned());
    mc.call(
        environment_id,
        "projects.mutate",
        json!({"type": "project.delete", "projectId": project_id}),
        Box::new(move |engine, result| {
            if let Err(error) = result {
                toast_error(engine, "Failed to remove project", &error.message);
                return;
            }
            // Its draft goes with its row (drafts); a window showing it goes
            // home.
            let Route::Draft(id) = navigation::shown(engine) else {
                return;
            };
            let shows_it = drafts::draft(engine, &id)
                .is_some_and(|d| d.environment_id == environment && d.project_id == project);
            if shows_it {
                controller::with::<Navigation, _>(engine, |n, e| n.replace(e, Route::Home));
            }
        }),
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_shorthand_is_a_github_repository_and_an_address_stays() {
        assert_eq!(
            normalize_pasted_url(" owner/repo "),
            "https://github.com/owner/repo.git"
        );
        assert_eq!(
            normalize_pasted_url("owner/repo.git"),
            "https://github.com/owner/repo.git"
        );
        assert_eq!(
            normalize_pasted_url(" https://example.com/a/b.git "),
            "https://example.com/a/b.git"
        );
        assert_eq!(normalize_pasted_url("git@host:a/b.git"), "git@host:a/b.git");
    }

    #[test]
    fn the_directory_is_the_last_segment_without_dot_git() {
        for (input, name) in [
            ("owner/repo", "repo"),
            ("https://github.com/owner/repo.git", "repo"),
            ("https://github.com/owner/repo.git?x=1#y", "repo"),
            ("git@github.com:owner/repo.git", "repo"),
            ("ssh://git@host:2222/team/app", "app"),
            ("https://host/", ""),
            ("https://host:8080", ""),
            ("git@host:", ""),
            ("", ""),
        ] {
            assert_eq!(directory_name(input), name, "{input}");
        }
    }

    #[test]
    fn the_destination_goes_under_the_folder_browsed() {
        assert_eq!(destination_path("~/dev/", "app"), "~/dev/app");
        assert_eq!(destination_path("~/dev", " app "), "~/dev/app");
        assert_eq!(destination_path(r"C:\dev\", "app"), r"C:\dev\app");
        assert_eq!(destination_path("~/dev/", " "), "~/dev/");
    }

    #[test]
    fn a_relative_destination_is_cleaned_under_the_root() {
        assert_eq!(clean_path("/home/me/proj/./sub"), "/home/me/proj/sub");
        assert_eq!(clean_path("/home/me/proj/../other"), "/home/me/other");
        assert_eq!(clean_path("/home/me/proj/.."), "/home/me");
        assert_eq!(clean_path("/../x"), "/x");
        assert_eq!(clean_path("a/../.."), "..");
        assert_eq!(clean_path("."), ".");
    }

    #[test]
    fn progress_reads_stage_percent_and_detail() {
        let clone = json!({"stage": "receiving", "percent": 42, "detail": "1.2 MiB"});
        assert_eq!(
            progress_summary(&clone),
            "Receiving objects · 42% · 1.2 MiB"
        );
        assert_eq!(
            progress_summary(&json!({"stage": "connecting"})),
            "Connecting"
        );
    }

    #[test]
    fn a_clone_is_named_by_its_repository_else_its_folder() {
        let named = json!({"repository": {"nameWithOwner": "o/r"}, "destinationPath": "/x/y"});
        assert_eq!(display_name(&named), "o/r");
        assert_eq!(display_name(&json!({"destinationPath": "/x/y/"})), "y");
        assert_eq!(display_name(&json!({"destinationPath": r"C:\a\b"})), "b");
    }
}
