//! `projects`, desktop-qt's ProjectController: adding and removing projects
//! on the MC the shell runs against, through `projects.mutate`.
//!
//! `project.add {path}` and `project.folder.open {path}` (the sidebar's
//! folder picker, a dropped folder, the folder explorer) open a local folder
//! as a project: one already registered opens its latest thread (or its
//! draft), a new one is created and opens a draft. A pathless `project.add`
//! runs the palette's Add project menu (registered here as [`ADD`]): the
//! online environment to add on when there are several, then its sources
//! (Local folder browses its folders; Git URL and the hosting providers
//! clone, `project_clone`). Both browse from the environment's
//! `addProjectBaseDirectory` setting, else the home folder.
//!
//! `project.remove {projectKey}` (`<environmentId>:<projectId>`, or a logical
//! project's key for its representative) asks first: it publishes
//! `projectRemoval` {projectKey, title, kind (project | checkout), count (the
//! entries removed), threadCount, workspaceRoot and environment (one entry's,
//! else "")} until `project.remove.confirm` deletes the projects with their
//! threads and drafts or `project.remove.cancel` keeps them, and null in
//! between. With `inSettings` (the folder explorer's) Settings → Project
//! opens on that project first. Settings asks about several of a logical
//! project's checkouts at once ([`ask_to_remove`]).
//!
//! `project.launch {path}` is a folder the app was started with, which
//! always gets a new thread.

use std::path::Path;
use std::rc::Rc;

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::commands::{Choice, Commands};
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::drafts;
use crate::controllers::navigation::{self, Navigation, Route};
use crate::controllers::project_clone;
use crate::controllers::sidebar;
use crate::controllers::toasts::Toasts;
use crate::environment_settings::EnvironmentSettings;
use crate::json::Json;
use crate::sidebar_model::{self as model, Thread};
use crate::store;

/// The palette's Add project.
pub const ADD: &str = "project.add";
const KEY: &str = "projectRemoval";

/// A folder ends in its separator, a backslash for a Windows path.
fn as_folder(path: &str) -> String {
    let trimmed = path.trim();
    if trimmed.is_empty() || trimmed.ends_with('/') {
        return trimmed.to_owned();
    }
    let bytes = trimmed.as_bytes();
    let drive = bytes.len() >= 3
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && matches!(bytes[2], b'/' | b'\\');
    let posix = trimmed.starts_with('/') || trimmed.starts_with('~');
    let windows = drive || trimmed.starts_with("\\\\") || (!posix && trimmed.contains('\\'));
    if windows && trimmed.ends_with('\\') {
        return trimmed.to_owned();
    }
    format!("{trimmed}{}", if windows { '\\' } else { '/' })
}

/// The project's thread still in play that was last written to: not
/// archived, not a subagent's, not settled by hand.
fn latest_thread(threads: Vec<Thread>, environment_id: &str, project_id: &str) -> Option<Thread> {
    let at = |t: &Thread| {
        model::parse_iso(t.latest_user_message_at.as_deref())
            .or_else(|| model::parse_iso(Some(&t.updated_at)))
            .unwrap_or(0)
    };
    let mut latest: Option<Thread> = None;
    for thread in threads {
        if thread.environment_id != environment_id
            || thread.project_id != project_id
            || thread.archived_at.is_some()
            || thread.subagent
            || thread.settled_override.as_deref() == Some("settled")
        {
            continue;
        }
        if latest.as_ref().is_none_or(|l| at(&thread) > at(l)) {
            latest = Some(thread);
        }
    }
    latest
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Removal {
    keys: Vec<String>,
    kind: String,
    title: String,
}

pub struct Projects {
    bridge: Bridge,
    me: Me<Projects>,
    /// The settings of the environment whose sources Add project last
    /// showed; shared with the menu, which runs where this may be running.
    settings: Rc<EnvironmentSettings>,
    active: bool,
    /// The projects waiting for the user's answer.
    removal: Option<Removal>,
    /// A project the MC created whose row has not reached the shell yet; its
    /// draft opens when the row does.
    created: Option<(String, String)>,
}

impl Controller for Projects {
    fn new(init: Init<'_, Self>) -> Self {
        Projects {
            bridge: init.bridge,
            me: init.me,
            settings: Rc::new(EnvironmentSettings::new(init.mc)),
            active: false,
            removal: None,
            created: None,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let me = self.me.clone();
        // A removal asked about a project that went away meanwhile has
        // nothing to ask.
        store::on_changed(engine, move |engine| {
            me.run(engine, |c, engine| c.store_changed(engine));
        });
        let settings = self.settings.clone();
        // Add project: an environment first when there is a choice, then how
        // to add: a local folder, or a clone (`project_clone`).
        let commands = Commands::of(engine);
        commands.add_menu(engine, ADD, "Add project", move |engine| {
            add_choices(engine, &settings)
        });
        commands.set_terms(
            ADD,
            &[
                "add project",
                "folder",
                "directory",
                "browse",
                "environment",
            ],
        );
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !self.active {
            return false;
        }
        let text = |key: &str| {
            payload
                .get(key)
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        match action {
            "project.launch" | "project.add" | "project.folder.open" => {
                let path = text("path");
                // Without a folder, the palette's Add project.
                if path.is_empty() {
                    return Commands::of(engine).run(engine, ADD);
                }
                // Where this machine's folders are not the MC's (an MC
                // elsewhere), nothing opens.
                if !self.bridge.local_folders(engine) {
                    return true;
                }
                open_folder(engine, &path, action == "project.launch");
                true
            }
            "project.remove" => {
                let key = text("projectKey");
                // From the folder explorer the removal is confirmed in
                // Settings → Project, on that project.
                if payload
                    .get("inSettings")
                    .and_then(Json::as_bool)
                    .unwrap_or(false)
                {
                    let logical = store::with(engine, |s| s.project(&key)).and_then(|p| {
                        sidebar::logical_project_key(engine, &p.environment_id, &p.id)
                    });
                    if let Some(logical) = logical {
                        self.bridge.dispatch(
                            engine,
                            "settingsScope.project",
                            json!({"key": logical}),
                        );
                        self.bridge.dispatch(
                            engine,
                            "settings.navigate",
                            json!({"to": "/settings/projects"}),
                        );
                    }
                }
                self.ask_by_key(engine, &key);
                true
            }
            "project.remove.confirm" => {
                self.confirm_removal(engine);
                true
            }
            "project.remove.cancel" => {
                self.removal = None;
                self.publish(engine);
                true
            }
            _ => false,
        }
    }
}

impl Projects {
    /// Where Add project browses on `environment_id` from, as a folder ("~/"
    /// unless its settings name another, once they have arrived).
    pub fn browse_start(&self, environment_id: &str) -> String {
        browse_start_in(&self.settings, environment_id)
    }

    /// Asks before removing the projects `keys` (`<environmentId>:<projectId>`)
    /// as one `kind` ("project" or "checkout") called `title`.
    pub fn ask_to_remove(&mut self, engine: &Engine, keys: Vec<String>, kind: &str, title: &str) {
        if keys.is_empty() {
            return;
        }
        self.removal = Some(Removal {
            keys,
            kind: kind.into(),
            title: title.into(),
        });
        self.publish(engine);
    }

    fn store_changed(&mut self, engine: &Engine) {
        if let Some(removal) = &mut self.removal {
            removal
                .keys
                .retain(|key| store::with(engine, |s| s.project(key)).is_some());
            if removal.keys.is_empty() {
                self.removal = None;
            }
            // Its threads may have changed too.
            self.publish(engine);
        }
        if let Some((environment_id, project_id)) = &self.created
            && store::with(engine, |s| {
                s.project(&format!("{environment_id}:{project_id}"))
            })
            .is_some()
        {
            let (environment_id, project_id) = (environment_id.clone(), project_id.clone());
            self.created = None;
            follow_in_sidebar(engine, &environment_id, &project_id);
            drafts::start(engine, &environment_id, &project_id);
        }
    }

    /// Asks about the project at `key`, or a logical project's
    /// representative.
    fn ask_by_key(&mut self, engine: &Engine, key: &str) {
        let mut key = key.to_owned();
        if store::with(engine, |s| s.project(&key)).is_none() {
            let Some(group) = sidebar::group(engine, &key) else {
                return;
            };
            let part = |name: &str| group.summary.get(name).and_then(Json::as_str).unwrap_or("");
            key = format!("{}:{}", part("environmentId"), part("projectId"));
        }
        let Some(project) = store::with(engine, |s| s.project(&key)) else {
            return;
        };
        self.ask_to_remove(engine, vec![key], "project", &project.title);
    }

    fn confirm_removal(&mut self, engine: &Engine) {
        let Some(removal) = self.removal.take() else {
            return;
        };
        self.publish(engine);
        remove(engine, removal.keys);
    }

    fn publish(&self, engine: &Engine) {
        if !self.active {
            return;
        }
        let project = self
            .removal
            .as_ref()
            .and_then(|r| r.keys.first())
            .and_then(|key| store::with(engine, |s| s.project(key)));
        let (Some(removal), Some(project)) = (&self.removal, project) else {
            self.bridge.publish(engine, KEY, Json::Null);
            return;
        };
        let threads = store::with(engine, |s| s.threads())
            .iter()
            .filter(|t| removal.keys.contains(&t.project_key()) && t.archived_at.is_none())
            .count();
        let one = removal.keys.len() == 1;
        let environment = || {
            let label = store::with(engine, |s| s.environment(&project.environment_id));
            label
                .get("label")
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        self.bridge.publish(
            engine,
            KEY,
            json!({
                "projectKey": project.key(),
                "title": removal.title,
                "kind": removal.kind,
                "count": removal.keys.len(),
                "workspaceRoot": if one { project.workspace_root.clone() } else { String::new() },
                "environment": if one { environment() } else { String::new() },
                "threadCount": threads,
            }),
        );
    }
}

/// Asks before removing the projects `keys` (`<environmentId>:<projectId>`)
/// as one `kind` called `title`: what Settings → Project calls.
pub fn ask_to_remove(engine: &Engine, keys: Vec<String>, kind: &str, title: &str) {
    controller::with::<Projects, _>(engine, |c, engine| {
        c.ask_to_remove(engine, keys, kind, title);
    });
}

/// Where Add project browses on `environment_id` from, as a folder.
pub fn browse_start(engine: &Engine, environment_id: &str) -> String {
    controller::with::<Projects, _>(engine, |c, _| c.browse_start(environment_id))
        .unwrap_or_else(|| "~/".into())
}

fn browse_start_in(settings: &EnvironmentSettings, environment_id: &str) -> String {
    let base = settings
        .settings(environment_id)
        .and_then(|s| {
            s.get("addProjectBaseDirectory")
                .and_then(Json::as_str)
                .map(as_folder)
        })
        .unwrap_or_default();
    if base.is_empty() { "~/".into() } else { base }
}

fn toast_error(engine: &Engine, title: &str, reason: &str) {
    controller::with::<Toasts, _>(engine, |t, e| {
        t.error(e, title, reason);
    });
}

fn label_of(engine: &Engine, environment_id: &str) -> String {
    store::with(engine, |s| s.environment(environment_id))
        .get("label")
        .and_then(Json::as_str)
        .unwrap_or_default()
        .to_owned()
}

/// The sources of the environment, after its settings say where browsing
/// starts: Local folder, then the clones.
fn sources(engine: &Engine, settings: &EnvironmentSettings, environment_id: &str) -> Vec<Choice> {
    settings.set_targets(&[environment_id.to_owned()]);
    let mut folder = Choice::new("local-folder", "Local folder", |_| {
        // TODO(port): CommandPaletteController::browse — browse the
        // environment's folders from `browse_start(engine, environment_id)`
        // with submit "Add", then `add_folder(engine, environment_id, path,
        // "Failed to add project", false)` on the path chosen.
    });
    folder.description = "Browse a folder on disk".into();
    folder.terms = ["folder", "directory", "browse"].map(String::from).to_vec();
    folder.keep_open = true;
    let mut choices = vec![folder];
    choices.extend(project_clone::sources(engine, environment_id));
    choices
}

/// Add project's first level: the sources of the one online environment, or
/// the environments to choose from.
fn add_choices(engine: &Engine, settings: &Rc<EnvironmentSettings>) -> Vec<Choice> {
    let (environments, online) = store::with(engine, |s| {
        let environments = s.environments();
        let online: Vec<String> = environments
            .iter()
            .filter(|e| s.environment_online(e))
            .cloned()
            .collect();
        (environments, online)
    });
    if let [only] = online.as_slice() {
        return sources(engine, settings, only);
    }
    let own = controller::mc(engine)
        .map(|mc| mc.environment())
        .unwrap_or_default();
    environments
        .into_iter()
        .map(|environment_id| {
            let label = match label_of(engine, &environment_id) {
                l if l.is_empty() => environment_id.clone(),
                l => l,
            };
            let connected = online.contains(&environment_id);
            let mut choice = Choice::new(&environment_id, &label, |_| {});
            choice.run = None;
            choice.description = if !connected {
                "Not connected".into()
            } else if environment_id == own {
                "This device".into()
            } else {
                environment_id.clone()
            };
            choice.enabled = connected;
            choice.terms = vec![environment_id.clone()];
            if environment_id == own {
                choice.terms.push("this device".into());
            }
            let settings = settings.clone();
            choice.submenu = Some(Rc::new({
                let environment_id = environment_id.clone();
                move |engine| sources(engine, &settings, &environment_id)
            }));
            choice
        })
        .collect()
}

/// Opens the folder at `path` on this machine's environment as a project;
/// a `new_thread` starts a thread in a project that is already there
/// instead of opening its latest one.
fn open_folder(engine: &Engine, path: &str, new_thread: bool) {
    const TITLE: &str = "Could not open folder";
    if !Path::new(path).is_dir() {
        toast_error(
            engine,
            TITLE,
            &format!("{path} is not a folder on this machine."),
        );
        return;
    }
    let mc = controller::mc(engine);
    let own = mc.as_ref().map(|mc| mc.environment()).unwrap_or_default();
    if !mc.is_some_and(|mc| mc.is_ready()) || own.is_empty() {
        toast_error(engine, TITLE, "The environment is not connected.");
        return;
    }
    let root = std::fs::canonicalize(path)
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| path.to_owned());
    add_folder(engine, &own, &root, TITLE, new_thread);
}

/// A scoped list follows the project the user just added or opened, so its
/// threads show and the next "New thread in" names it. An unscoped list
/// stays.
pub fn follow_in_sidebar(engine: &Engine, environment_id: &str, project_id: &str) {
    let Some(scope) = sidebar::scope(engine) else {
        return;
    };
    let key = sidebar::logical_project_key(engine, environment_id, project_id)
        .unwrap_or_else(|| format!("{environment_id}:{project_id}"));
    if scope == key {
        return;
    }
    Bridge::of(engine).dispatch(engine, "sidebar.scope", json!({"projectKey": key}));
}

/// Adds the folder as a project of the environment, or opens the one it
/// already is. A refusal is told under `failure_title`: opening a folder
/// from this machine says "Could not open folder", the palette's Add project
/// "Failed to add project". `new_thread` starts a thread in a project that
/// is already there instead of opening its latest one (a folder the app was
/// launched with).
pub fn add_folder(
    engine: &Engine,
    environment_id: &str,
    root: &str,
    failure_title: &str,
    new_thread: bool,
) {
    // The environment chosen went away while the folder was being picked.
    if !store::with(engine, |s| s.environment_online(environment_id)) {
        let label = match label_of(engine, environment_id) {
            l if l.is_empty() => environment_id.to_owned(),
            l => l,
        };
        toast_error(
            engine,
            "Environment unavailable",
            &format!("{label} is not connected."),
        );
        return;
    }
    let normalized = model::normalize_path(root);
    let found = store::with(engine, |s| s.projects()).into_iter().find(|p| {
        p.environment_id == environment_id && model::normalize_path(&p.workspace_root) == normalized
    });
    if let Some(project) = found {
        if new_thread {
            follow_in_sidebar(engine, environment_id, &project.id);
            drafts::start(engine, environment_id, &project.id);
        } else {
            open_project(engine, environment_id, &project.id);
        }
        return;
    }
    let Some(mc) = controller::mc(engine) else {
        return;
    };
    let project_id = hal_c2_mc::new_uuid();
    let command = json!({
        "type": "project.create",
        "projectId": project_id,
        "workspaceRoot": root,
    });
    let environment = environment_id.to_owned();
    let failure_title = failure_title.to_owned();
    mc.call(
        environment_id,
        "projects.mutate",
        command,
        Box::new(move |engine, result| {
            if let Err(error) = result {
                toast_error(engine, &failure_title, &error.message);
                return;
            }
            // A draft for a project the shell has no row for would be
            // dropped as orphaned, so it waits for the row if the answer
            // came first.
            if store::with(engine, |s| {
                s.project(&format!("{environment}:{project_id}"))
            })
            .is_some()
            {
                follow_in_sidebar(engine, &environment, &project_id);
                drafts::start(engine, &environment, &project_id);
            } else {
                controller::with::<Projects, _>(engine, |c, _| {
                    c.created = Some((environment, project_id));
                });
            }
        }),
    );
}

/// Opens the project's latest thread still in play, else its draft.
fn open_project(engine: &Engine, environment_id: &str, project_id: &str) {
    follow_in_sidebar(engine, environment_id, project_id);
    let threads = store::with(engine, |s| s.threads());
    match latest_thread(threads, environment_id, project_id) {
        Some(thread) => {
            controller::with::<Navigation, _>(engine, |n, e| {
                n.open(e, Route::Thread(thread.key()))
            });
        }
        None => {
            drafts::start(engine, environment_id, project_id);
        }
    }
}

/// Deletes the first of `keys`, then the rest; a failure stops there.
fn remove(engine: &Engine, mut keys: Vec<String>) {
    if keys.is_empty() {
        return;
    }
    let Some(project) = store::with(engine, |s| s.project(&keys.remove(0))) else {
        remove(engine, keys);
        return;
    };
    let Some(mc) = controller::mc(engine) else {
        return;
    };
    // Leave the project now if the window shows it, before its rows vanish.
    let showing = match navigation::shown(engine) {
        Route::Thread(key) => store::with(engine, |s| s.thread(&key)).is_some_and(|t| {
            t.environment_id == project.environment_id && t.project_id == project.id
        }),
        Route::Draft(id) => drafts::draft(engine, &id).is_some_and(|d| {
            d.environment_id == project.environment_id && d.project_id == project.id
        }),
        _ => false,
    };
    let command = json!({
        "type": "project.delete",
        "projectId": project.id,
        // Its threads go with it; the confirmation said so.
        "force": true,
    });
    mc.call(
        &project.environment_id,
        "projects.mutate",
        command,
        Box::new(move |engine, result| {
            if let Err(error) = result {
                toast_error(engine, "Failed to remove project", &error.message);
                return;
            }
            // Its drafts go as its row does (drafts).
            if showing {
                controller::with::<Navigation, _>(engine, |n, e| n.replace(e, Route::Home));
            }
            remove(engine, keys);
        }),
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    fn thread(id: &str, updated: &str, latest: Option<&str>) -> Thread {
        Thread {
            environment_id: "e".into(),
            project_id: "p".into(),
            id: id.into(),
            updated_at: updated.into(),
            latest_user_message_at: latest.map(Into::into),
            ..Thread::default()
        }
    }

    #[test]
    fn a_folder_ends_in_its_separator() {
        assert_eq!(as_folder(" /home/me "), "/home/me/");
        assert_eq!(as_folder("~/dev/"), "~/dev/");
        assert_eq!(as_folder(r"C:\Users\me"), r"C:\Users\me\");
        assert_eq!(as_folder(r"C:\Users\me\"), r"C:\Users\me\");
        assert_eq!(as_folder(r"\\host\share"), r"\\host\share\");
        assert_eq!(as_folder(""), "");
    }

    #[test]
    fn the_latest_thread_is_the_last_written_to_one_in_play() {
        let mut archived = thread("archived", "2026-03-01T00:00:00Z", None);
        archived.archived_at = Some("2026-03-02T00:00:00Z".into());
        let mut settled = thread("settled", "2026-03-01T00:00:00Z", None);
        settled.settled_override = Some("settled".into());
        let mut sub = thread("sub", "2026-03-01T00:00:00Z", None);
        sub.subagent = true;
        let mut elsewhere = thread("elsewhere", "2026-03-01T00:00:00Z", None);
        elsewhere.project_id = "q".into();
        let threads = vec![
            thread("old", "2026-01-01T00:00:00Z", None),
            // Written by the user later than the others were updated.
            thread("said", "2026-01-01T00:00:00Z", Some("2026-02-01T00:00:00Z")),
            thread("busy", "2026-01-15T00:00:00Z", None),
            archived,
            settled,
            sub,
            elsewhere,
        ];
        assert_eq!(
            latest_thread(threads.clone(), "e", "p").map(|t| t.id),
            Some("said".into())
        );
        assert_eq!(latest_thread(threads, "e", "none"), None);
    }
}
