//! `projectActions`, desktop-qt's ProjectActionsController: the actions of
//! the project the window shows (its route's thread or draft), beyond
//! running them (WorkspaceController, TerminalController): adding, editing
//! and deleting them, their shortcuts, and what the checkout's hal-c2.json
//! offers. Actions are the project's `scripts`, saved with `projects.mutate`
//! (project.update); a shortcut is the `script.<id>.run` rule of the
//! environment's keybindings.json.
//!
//! Publishes `projectActions`, null away from a project:
//! {projectKey, scripts: [{id, name, command, icon, setup, shortcut}],
//! editor: {scriptId (empty for a new one), name, command, icon,
//! runOnWorktreeCreate, waitForSetup, keybinding, previewUrl,
//! autoOpenPreview, canAutoOpenPreview, error, saving} | null, file:
//! "loading" | "missing" | "invalid" | "valid", imports: [{name, command,
//! icon}]} (hal-c2.json's, not yet the project's).
//!
//! Actions: `projectActions.add`, `projectActions.edit {scriptId}`,
//! `projectActions.set {<field>: value, ...}` (the editor's fields),
//! `projectActions.save`, `projectActions.cancel`, `projectActions.delete
//! {scriptId?}` (the editor's without one), which asks first (Menus'
//! confirmation), and `projectActions.import {name?}` (every offered one
//! without a name). Palette command `projectActions.add` ("Add project
//! action").
//!
//! In Settings → Project the same list is the settings scope's instead: with
//! no project picked the selected environments' `defaultProjectScripts`,
//! which every project without a list of its own offers
//! ([`crate::project::scripts`]), else the picked project's own list, kept
//! as its `defaultProjectScripts` override on each environment with a
//! checkout (an environment too old for overrides is left out). The state
//! then also has {settings: true, project (one is picked), available, mixed
//! (the environments' lists differ), own (the project has its own list)}, a
//! script also says `preview`, and the actions are `projectActions.add
//! {name, command, ...}` (added at once), `projectActions.delete
//! {scriptId}`, `projectActions.reset` (a project inherits again) and
//! `projectActions.import {name?}`.
//!
//! A project's own list is written where it is kept: its override once it
//! has one, else its row's `scripts` (`projects.mutate`).
//!
//! It also gives a new thread's draft the project's default workspace: the
//! project's or environment's `defaultThreadEnvMode` setting, else what
//! hal-c2.json says, else the current checkout.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::commands::Commands;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::drafts;
use crate::controllers::keybindings::Keymap;
use crate::controllers::menus::Menus;
use crate::controllers::settings::{Map, Settings};
use crate::controllers::settings_scope::SettingsScope;
use crate::controllers::toasts::Toasts;
use crate::controllers::workspace::{self, Checkout};
use crate::environment_settings::{Edit, EnvironmentSettings};
use crate::json::Json;
use crate::keybindings;
use crate::mc::Mc;
use crate::project::file::{self, File, Script};
use crate::project::scripts;
use crate::settings_page;
use crate::store;

/// The palette's Add project action.
pub const ADD: &str = "projectActions.add";
const KEY: &str = "projectActions";
const SECTION: &str = "/settings/projects";
const SCRIPTS: &str = "defaultProjectScripts";
const SAVE_FAILED: &str = "Failed to save project actions";

/// packages/contracts MAX_SCRIPT_ID_LENGTH.
const MAX_ID_LENGTH: usize = 24;

fn text<'a>(object: &'a Json, key: &str) -> &'a str {
    settings_page::text(object, key)
}

fn command(script_id: &str) -> String {
    format!("script.{script_id}.run")
}

/// A new action's id: its name in lower case with dashes, numbered when
/// taken.
pub fn next_id(name: &str, taken: &HashSet<String>) -> String {
    let mut base = String::new();
    let mut dash = false;
    for c in name.trim().to_lowercase().chars() {
        if c.is_ascii_lowercase() || c.is_ascii_digit() {
            if dash && !base.is_empty() {
                base.push('-');
            }
            dash = false;
            base.push(c);
        } else {
            dash = true;
        }
    }
    base.truncate(MAX_ID_LENGTH);
    let mut base = base.trim_end_matches('-').to_owned();
    if base.is_empty() {
        base = "script".to_owned();
    }
    if !taken.contains(&base) {
        return base;
    }
    (2..)
        .map(|suffix| {
            let tail = format!("-{suffix}");
            let keep = MAX_ID_LENGTH
                .saturating_sub(tail.len())
                .max(1)
                .min(base.len());
            format!("{}{tail}", &base[..keep])
        })
        .find(|candidate| !taken.contains(candidate))
        .unwrap_or(base)
}

fn to_script(script: &Script, id: &str) -> Json {
    let mut object = json!({
        "id": id,
        "name": script.name,
        "command": script.command,
        "icon": script.icon,
        "runOnWorktreeCreate": script.run_on_worktree_create,
    });
    if script.run_on_worktree_create && script.r#async == Some(false) {
        object["async"] = Json::Bool(false);
    }
    if !script.preview_url.is_empty() {
        object["previewUrl"] = script.preview_url.clone().into();
        object["autoOpenPreview"] = script.auto_open_preview.into();
    }
    object
}

fn flag(object: &Json, key: &str) -> bool {
    object.get(key).and_then(Json::as_bool).unwrap_or(false)
}

/// `scripts` with `script` added; one action is the setup script, so a
/// setup `script` takes the flag from the others.
fn appended(mut scripts: Vec<Json>, script: Json) -> Vec<Json> {
    if flag(&script, "runOnWorktreeCreate") {
        for other in &mut scripts {
            if let Some(fields) = other.as_object_mut() {
                fields.insert("runOnWorktreeCreate".into(), Json::Bool(false));
            }
        }
    }
    scripts.push(script);
    scripts
}

/// What a row or file offers as an import.
fn import_json(script: &Script) -> Json {
    json!({"name": script.name, "command": script.command, "icon": script.icon})
}

/// The `scripts` of the environment's project rows, whose ids are the
/// environment's: a shortcut names an action by its id alone.
fn rows_scripts(engine: &Engine, environment_id: &str) -> Vec<(String, Vec<Json>)> {
    store::with(engine, |s| {
        s.project_rows(environment_id)
            .into_iter()
            .map(|row| {
                (
                    row.get("id")
                        .and_then(Json::as_str)
                        .unwrap_or_default()
                        .to_owned(),
                    row.get("scripts")
                        .and_then(Json::as_array)
                        .cloned()
                        .unwrap_or_default(),
                )
            })
            .collect()
    })
}

fn row_scripts(engine: &Engine, environment_id: &str, project_id: &str) -> Vec<Json> {
    store::with(engine, |s| {
        s.project_row(environment_id, project_id)
            .and_then(|row| row.get("scripts"))
            .and_then(Json::as_array)
            .cloned()
    })
    .unwrap_or_default()
}

fn error_toast(engine: &Engine, title: &str, description: &str) {
    controller::with::<Toasts, _>(engine, |toasts, engine| {
        toasts.error(engine, title, description);
    });
}

/// What the editor holds while an action is added or edited.
struct Editor {
    script_id: String,
    name: String,
    command: String,
    icon: String,
    run_on_worktree_create: bool,
    wait_for_setup: bool,
    keybinding: String,
    preview_url: String,
    auto_open_preview: bool,
    error: String,
    saving: bool,
}

impl Default for Editor {
    fn default() -> Self {
        Editor {
            script_id: String::new(),
            name: String::new(),
            command: String::new(),
            icon: "play".into(),
            run_on_worktree_create: false,
            wait_for_setup: false,
            keybinding: String::new(),
            preview_url: String::new(),
            auto_open_preview: false,
            error: String::new(),
            saving: false,
        }
    }
}

impl Editor {
    fn to_json(&self) -> Json {
        json!({
            "scriptId": self.script_id,
            "name": self.name,
            "command": self.command,
            "icon": self.icon,
            "runOnWorktreeCreate": self.run_on_worktree_create,
            "waitForSetup": self.wait_for_setup,
            "keybinding": self.keybinding,
            "previewUrl": self.preview_url,
            "autoOpenPreview": self.auto_open_preview,
            "canAutoOpenPreview": !self.preview_url.trim().is_empty(),
            "error": self.error,
            "saving": self.saving,
        })
    }
}

/// A selected environment's list in Settings → Project: for its project's
/// checkout there, or the environment's defaults (`project_id` empty).
struct Target {
    environment_id: String,
    project_id: String,
    settings: Json,
}

/// What a write tells the controller once the MC answered: why it failed,
/// or nothing.
type Done = Box<dyn FnOnce(&mut ProjectActions, &Engine, Option<String>)>;

pub struct ProjectActions {
    bridge: Bridge,
    me: Me<ProjectActions>,
    mc: Rc<dyn Mc>,
    /// The shown project's environment, for its settings.
    settings: EnvironmentSettings,
    active: bool,
    /// The route as last published.
    route: Json,
    /// The route is Settings → Project.
    settings_open: bool,
    /// The project shown: its environment, id and scripts, and its checkout.
    environment: String,
    project: String,
    cwd: String,
    scripts: Vec<Json>,
    editor: Option<Editor>,
    /// The checkout's hal-c2.json.
    file_status: &'static str,
    file: Option<File>,
    /// The thread or draft the file was last read for: each one shown reads
    /// it again, so an edited file is seen without a restart.
    file_for: String,
    shown: String,
    file_request: u32,
    /// Drafts whose default workspace was decided.
    placed: HashSet<String>,
    /// Those it moved off the current checkout.
    applied: HashSet<String>,
    published: Json,
}

impl Controller for ProjectActions {
    fn new(init: Init<'_, Self>) -> Self {
        ProjectActions {
            bridge: init.bridge,
            me: init.me,
            settings: EnvironmentSettings::new(init.mc.clone()),
            mc: init.mc,
            active: false,
            route: Json::Null,
            settings_open: false,
            environment: String::new(),
            project: String::new(),
            cwd: String::new(),
            scripts: Vec::new(),
            editor: None,
            file_status: "missing",
            file: None,
            file_for: String::new(),
            shown: String::new(),
            file_request: 0,
            placed: HashSet::new(),
            applied: HashSet::new(),
            published: Json::Null,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let me = self.me.clone();
        workspace::on_place_changed(engine, move |engine| {
            me.run(engine, |c, engine| c.follow(engine));
        });
        let me = self.me.clone();
        self.settings.on_changed(move |engine| {
            me.run(engine, |c, engine| c.apply_default_workspace(engine));
        });
        // Asking for a new thread asks again where it starts: the draft may
        // be the project's untouched one from before hal-c2.json or the
        // setting changed.
        let me = self.me.clone();
        drafts::on_started(engine, move |engine, draft_id| {
            let draft_id = draft_id.to_owned();
            me.run(engine, move |c, engine| {
                // One it already placed is the user's to move from then on.
                if c.applied.contains(&draft_id) {
                    return;
                }
                c.placed.remove(&draft_id);
                if c.shown == draft_id {
                    c.read_file(engine, false);
                }
                c.follow(engine);
            });
        });
        let me = self.me.clone();
        self.bridge.watch(engine, "route", move |engine, route| {
            let route = route.clone();
            me.run(engine, move |c, engine| {
                c.route = route;
                c.follow(engine);
            });
        });
        let me = self.me.clone();
        SettingsScope::of(engine).on_changed(move |engine| {
            me.run(engine, |c, engine| {
                if c.settings_open {
                    c.follow(engine);
                }
            });
        });
        let me = self.me.clone();
        store::on_changed(engine, move |engine| {
            me.run(engine, |c, engine| {
                if c.settings_open {
                    c.publish(engine);
                }
            });
        });
        // The keymap has no bindings-changed hook; it follows the same
        // config frames and was activated first, so its rules are in by the
        // time this runs.
        let me = self.me.clone();
        Settings::of(engine).on_config_changed(move |engine| {
            me.run(engine, |c, engine| c.publish(engine));
        });
        let commands = Commands::of(engine);
        let me = self.me.clone();
        commands.add(engine, ADD, "Add project action", move |engine| {
            me.run(engine, |c, engine| c.edit(engine, ""));
        });
        commands.set_terms(ADD, &["script", "command", "run"]);
        self.route = self.bridge.published(engine, "route").unwrap_or(Json::Null);
        self.follow(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !action.starts_with("projectActions.") {
            return false;
        }
        if self.active && self.settings_open {
            self.handle_settings(engine, action, payload);
            return true;
        }
        if !self.active || self.project.is_empty() {
            return true;
        }
        match action {
            ADD => self.edit(engine, ""),
            "projectActions.edit" => self.edit(engine, text(payload, "scriptId")),
            "projectActions.set" => self.set(engine, payload),
            "projectActions.save" => self.save(engine),
            "projectActions.cancel" => {
                self.editor = None;
                self.publish(engine);
            }
            "projectActions.delete" => {
                let script_id = match (text(payload, "scriptId"), &self.editor) {
                    ("", Some(editor)) => editor.script_id.clone(),
                    (script_id, _) => script_id.to_owned(),
                };
                self.ask_to_delete(engine, &script_id);
            }
            "projectActions.import" => self.import_scripts(engine, text(payload, "name")),
            _ => return false,
        }
        true
    }
}

impl ProjectActions {
    fn follow(&mut self, engine: &Engine) {
        self.settings_open = settings_page::shows(&self.route, &[SECTION]);
        if self.settings_open {
            // The picked project's hal-c2.json, from its first checkout in
            // the scope.
            let scope = SettingsScope::of(engine);
            let mut environment = String::new();
            let mut cwd = String::new();
            if scope.project_scope() {
                for candidate in scope.targets() {
                    let project = scope.project_on(&candidate);
                    cwd = store::with(engine, |s| {
                        s.project_row(&candidate, &project)
                            .and_then(|row| row.get("workspaceRoot"))
                            .and_then(Json::as_str)
                            .map(str::to_owned)
                    })
                    .unwrap_or_default();
                    if cwd.is_empty() {
                        continue;
                    }
                    environment = candidate;
                    break;
                }
            }
            self.editor = None;
            self.project.clear();
            self.scripts.clear();
            let shown = format!("settings\n{environment}\n{cwd}");
            if environment != self.environment || cwd != self.cwd || shown != self.shown {
                self.environment = environment;
                self.cwd = cwd;
                self.shown = shown;
                self.read_file(engine, true);
            }
            self.publish(engine);
            return;
        }
        let place = workspace::place(engine);
        let environment = place
            .as_ref()
            .map(|p| p.environment_id.clone())
            .unwrap_or_default();
        let project = place
            .as_ref()
            .map(|p| p.project_id.clone())
            .unwrap_or_default();
        if environment != self.environment || project != self.project {
            self.environment = environment.clone();
            self.project = project;
            self.editor = None;
            self.settings.set_targets(&[environment]);
        }
        self.scripts = place
            .as_ref()
            .map(|p| p.scripts.clone())
            .unwrap_or_default();
        Commands::of(engine).set_enabled(engine, ADD, !self.project.is_empty());
        let cwd = place
            .as_ref()
            .map(|p| p.cwd().to_owned())
            .unwrap_or_default();
        let shown = match &place {
            None => String::new(),
            Some(p) if p.draft_id.is_empty() => p.thread_key(),
            Some(p) => p.draft_id.clone(),
        };
        if cwd != self.cwd || shown != self.shown {
            let moved = cwd != self.cwd;
            self.cwd = cwd;
            self.shown = shown;
            self.read_file(engine, moved);
        }
        self.apply_default_workspace(engine);
        self.publish(engine);
    }

    /// `moved`: another checkout, whose file is not known yet; the same one
    /// keeps what was read until the new read lands.
    fn read_file(&mut self, _engine: &Engine, moved: bool) {
        self.file_request += 1;
        let request = self.file_request;
        self.file_for.clear();
        if moved || self.cwd.is_empty() {
            self.file = None;
            self.file_status = if self.cwd.is_empty() {
                "missing"
            } else {
                "loading"
            };
        }
        if self.cwd.is_empty() {
            return;
        }
        let shown = self.shown.clone();
        let me = self.me.clone();
        self.mc.call(
            &self.environment,
            "projects.readFile",
            json!({"cwd": self.cwd, "relativePath": file::NAME}),
            Box::new(move |engine, result| {
                me.run(engine, move |c, engine| {
                    if request != c.file_request {
                        return;
                    }
                    c.file_for = shown;
                    match result {
                        Ok(read) if !flag(&read, "truncated") => {
                            c.file = file::parse(text(&read, "contents"));
                            c.file_status = if c.file.is_some() { "valid" } else { "invalid" };
                        }
                        _ => {
                            c.file = None;
                            c.file_status = "missing";
                        }
                    }
                    c.apply_default_workspace(engine);
                    c.publish(engine);
                });
            }),
        );
    }

    /// A draft the user has not placed yet starts where the project's
    /// default says: a saved setting first, then hal-c2.json.
    fn apply_default_workspace(&mut self, engine: &Engine) {
        let Some(place) = workspace::place(engine) else {
            return;
        };
        if place.draft_id.is_empty() || self.placed.contains(&place.draft_id) {
            return;
        }
        let Some(settings) = self.settings.settings(&place.environment_id) else {
            return;
        };
        let key = "defaultThreadEnvMode";
        let saved = settings
            .as_object()
            .and_then(|s| SettingsScope::override_of(s, &place.project_id, key))
            .filter(Json::is_string)
            .or_else(|| settings.get(key).cloned());
        let mut mode = saved
            .as_ref()
            .and_then(Json::as_str)
            .unwrap_or_default()
            .to_owned();
        if mode.is_empty() {
            // The file decides, once it has been read.
            if self.file_for != place.draft_id {
                return;
            }
            if let Some(file) = &self.file {
                mode = file.default_thread_env_mode.clone();
            }
        }
        let draft_id = place.draft_id;
        self.placed.insert(draft_id.clone());
        let mut checkout = workspace::checkout(engine, &draft_id);
        let untouched = Checkout::default();
        let placed = checkout.env_mode != untouched.env_mode
            || checkout.branch.is_some()
            || checkout.worktree_path.is_some()
            || !checkout.environment_id.is_empty();
        if placed || mode.is_empty() || mode == checkout.env_mode {
            return;
        }
        checkout.env_mode = mode;
        self.applied.insert(draft_id.clone());
        workspace::set_checkout(engine, &draft_id, checkout);
    }

    /// The key bound to the action, as the newest binding says it, or "".
    fn shortcut_of(&self, engine: &Engine, script_id: &str) -> String {
        let command = command(script_id);
        Keymap::of(engine)
            .bindings()
            .iter()
            .rev()
            .find(|b| b.command == command)
            .map(|b| keybindings::key_text(&b.shortcut))
            .unwrap_or_default()
    }

    /// The shortcut as the lists show it.
    fn shortcut_label(&self, engine: &Engine, script_id: &str) -> String {
        match self.shortcut_of(engine, script_id) {
            key if key.is_empty() => String::new(),
            key => Keymap::of(engine).key_label(&key),
        }
    }

    /// What hal-c2.json offers that the list does not have (by command or
    /// name).
    fn importable(&self, engine: &Engine) -> Vec<Script> {
        let Some(file) = &self.file else {
            return Vec::new();
        };
        // In settings, against the first selected environment's list.
        let listed = if self.settings_open {
            self.settings_targets(engine)
                .first()
                .map(|t| self.scripts_on(engine, t))
                .unwrap_or_default()
        } else {
            self.scripts.clone()
        };
        file.scripts
            .iter()
            .filter(|candidate| {
                !listed.iter().any(|script| {
                    text(script, "command") == candidate.command
                        || text(script, "name").to_lowercase() == candidate.name.to_lowercase()
                })
            })
            .cloned()
            .collect()
    }

    fn script_rows(&self, engine: &Engine, listed: &[Json], with_preview: bool) -> Vec<Json> {
        listed
            .iter()
            .map(|script| {
                let mut row = json!({
                    "id": text(script, "id"),
                    "name": text(script, "name"),
                    "command": text(script, "command"),
                    "icon": text(script, "icon"),
                    "setup": flag(script, "runOnWorktreeCreate"),
                    "shortcut": self.shortcut_label(engine, text(script, "id")),
                });
                if with_preview {
                    row["preview"] = Json::Bool(!text(script, "previewUrl").is_empty());
                }
                row
            })
            .collect()
    }

    fn publish(&mut self, engine: &Engine) {
        let state = if self.settings_open {
            self.settings_state(engine)
        } else if !self.project.is_empty() {
            let imports: Vec<Json> = self.importable(engine).iter().map(import_json).collect();
            json!({
                "projectKey": format!("{}:{}", self.environment, self.project),
                "scripts": self.script_rows(engine, &self.scripts, false),
                "editor": self.editor.as_ref().map_or(Json::Null, Editor::to_json),
                "file": self.file_status,
                "imports": imports,
            })
        } else {
            Json::Null
        };
        if state == self.published {
            return;
        }
        self.published = state.clone();
        self.bridge.publish(engine, KEY, state);
    }

    /// Starts the editor on the action (a new one without an id).
    fn edit(&mut self, engine: &Engine, script_id: &str) {
        let mut editor = Editor::default();
        if !script_id.is_empty() {
            let Some(script) = self
                .scripts
                .iter()
                .find(|s| text(s, "id") == script_id)
                .cloned()
            else {
                return;
            };
            editor.script_id = script_id.to_owned();
            editor.name = text(&script, "name").to_owned();
            editor.command = text(&script, "command").to_owned();
            editor.icon = text(&script, "icon").to_owned();
            editor.run_on_worktree_create = flag(&script, "runOnWorktreeCreate");
            editor.wait_for_setup =
                editor.run_on_worktree_create && script.get("async") == Some(&Json::Bool(false));
            editor.keybinding = self.shortcut_of(engine, script_id);
            editor.preview_url = text(&script, "previewUrl").to_owned();
            editor.auto_open_preview = flag(&script, "autoOpenPreview");
        }
        self.editor = Some(editor);
        self.publish(engine);
    }

    fn set(&mut self, engine: &Engine, fields: &Json) {
        let Some(editor) = &mut self.editor else {
            return;
        };
        if editor.saving {
            return;
        }
        let has = |key: &str| fields.get(key).is_some();
        let value = |key: &str| text(fields, key).to_owned();
        if has("name") {
            editor.name = value("name");
        }
        if has("command") {
            editor.command = value("command");
        }
        if has("icon") && file::ICONS.contains(&text(fields, "icon")) {
            editor.icon = value("icon");
        }
        if has("runOnWorktreeCreate") {
            editor.run_on_worktree_create = settings_page::flag(fields.get("runOnWorktreeCreate"));
        }
        if has("waitForSetup") {
            editor.wait_for_setup = settings_page::flag(fields.get("waitForSetup"));
        }
        if has("keybinding") {
            editor.keybinding = value("keybinding");
        }
        if has("previewUrl") {
            editor.preview_url = value("previewUrl");
        }
        // Opening the preview needs an address to open.
        if has("autoOpenPreview") {
            editor.auto_open_preview = settings_page::flag(fields.get("autoOpenPreview"));
        }
        if editor.preview_url.trim().is_empty() {
            editor.auto_open_preview = false;
        }
        if !editor.run_on_worktree_create {
            editor.wait_for_setup = false;
        }
        editor.error.clear();
        self.publish(engine);
    }

    fn save(&mut self, engine: &Engine) {
        let Some(editor) = &mut self.editor else {
            return;
        };
        if editor.saving {
            return;
        }
        let name = editor.name.trim().to_owned();
        let command_line = editor.command.trim().to_owned();
        let key = editor.keybinding.trim().to_owned();
        if name.is_empty() {
            editor.error = "Name is required.".into();
        } else if command_line.is_empty() {
            editor.error = "Command is required.".into();
        } else if !key.is_empty() && keybindings::parse_shortcut(&key).is_none() {
            editor.error = "Invalid keybinding.".into();
        }
        if !editor.error.is_empty() {
            self.publish(engine);
            return;
        }
        let mut id = editor.script_id.clone();
        let added = id.is_empty();
        let mut next = json!({
            "id": id,
            "name": name,
            "command": command_line,
            "icon": editor.icon,
            "runOnWorktreeCreate": editor.run_on_worktree_create,
        });
        if editor.run_on_worktree_create && editor.wait_for_setup {
            next["async"] = Json::Bool(false);
        }
        let preview = editor.preview_url.trim().to_owned();
        if !preview.is_empty() {
            next["previewUrl"] = preview.into();
            next["autoOpenPreview"] = editor.auto_open_preview.into();
        }
        let setup = editor.run_on_worktree_create;
        if added {
            // Ids are an environment's: a shortcut names the action by its
            // id alone.
            let taken: HashSet<String> = rows_scripts(engine, &self.environment)
                .iter()
                .flat_map(|(_, scripts)| scripts.iter())
                .map(|s| text(s, "id").to_owned())
                .collect();
            id = next_id(&name, &taken);
            next["id"] = id.clone().into();
        }
        let mut scripts = Vec::new();
        for script in &self.scripts {
            if text(script, "id") == id {
                scripts.push(next.clone());
            } else if setup {
                // One setup script: the others stop running on worktree
                // creation.
                let mut other = script.clone();
                if let Some(fields) = other.as_object_mut() {
                    fields.insert("runOnWorktreeCreate".into(), Json::Bool(false));
                }
                scripts.push(other);
            } else {
                scripts.push(script.clone());
            }
        }
        if added {
            scripts.push(next);
        }
        if let Some(editor) = &mut self.editor {
            editor.saving = true;
        }
        self.publish(engine);
        self.write(
            engine,
            scripts,
            Box::new(move |c, engine, error| {
                let Some(editor) = &mut c.editor else {
                    return;
                };
                editor.saving = false;
                if let Some(error) = error {
                    editor.error = if error.is_empty() {
                        "Failed to save action.".into()
                    } else {
                        error
                    };
                    c.publish(engine);
                    return;
                }
                c.editor = None;
                c.bind(engine, &id, &key);
                c.publish(engine);
            }),
        );
    }

    fn ask_to_delete(&mut self, engine: &Engine, script_id: &str) {
        let name = self
            .scripts
            .iter()
            .filter(|s| text(s, "id") == script_id)
            .map(|s| text(s, "name").to_owned())
            .next_back()
            .unwrap_or_default();
        if script_id.is_empty() || name.is_empty() {
            return;
        }
        let project = format!("{}:{}", self.environment, self.project);
        let script_id = script_id.to_owned();
        let me = self.me.clone();
        controller::with::<Menus, _>(engine, |menus, engine| {
            menus.confirm(
                engine,
                &format!("Delete action \"{name}\"?"),
                "This action cannot be undone.",
                "Delete action",
                true,
                Some(Rc::new(move |engine| {
                    let (project, script_id) = (project.clone(), script_id.clone());
                    me.run(engine, move |c, engine| {
                        // Still the project the question was about.
                        if project == format!("{}:{}", c.environment, c.project) {
                            c.remove(engine, &script_id);
                        }
                    });
                })),
                None,
            );
        });
    }

    fn remove(&mut self, engine: &Engine, id: &str) {
        let scripts: Vec<Json> = self
            .scripts
            .iter()
            .filter(|s| text(s, "id") != id)
            .cloned()
            .collect();
        if scripts.len() == self.scripts.len() {
            return;
        }
        let id = id.to_owned();
        self.write(
            engine,
            scripts,
            Box::new(move |c, engine, error| {
                if let Some(error) = error {
                    error_toast(engine, SAVE_FAILED, &error);
                    return;
                }
                if c.editor.as_ref().is_some_and(|e| e.script_id == id) {
                    c.editor = None;
                }
                c.bind(engine, &id, "");
                c.publish(engine);
            }),
        );
    }

    fn import_scripts(&mut self, engine: &Engine, name: &str) {
        let mut scripts = self.scripts.clone();
        let mut taken: HashSet<String> = rows_scripts(engine, &self.environment)
            .iter()
            .flat_map(|(_, scripts)| scripts.iter())
            .map(|s| text(s, "id").to_owned())
            .collect();
        let mut setup = scripts.iter().any(|s| flag(s, "runOnWorktreeCreate"));
        for mut script in self.importable(engine) {
            if !name.is_empty() && script.name != name {
                continue;
            }
            // The project keeps the setup script it has.
            if setup {
                script.run_on_worktree_create = false;
            }
            setup = setup || script.run_on_worktree_create;
            let id = next_id(&script.name, &taken);
            taken.insert(id.clone());
            scripts.push(to_script(&script, &id));
        }
        if scripts.len() == self.scripts.len() {
            return;
        }
        self.write(
            engine,
            scripts,
            Box::new(|_, engine, error| {
                if let Some(error) = error {
                    error_toast(engine, "Failed to import action.", &error);
                }
            }),
        );
    }

    /// Replaces the project's scripts; `done` hears why it failed, or
    /// nothing. A project whose list Settings made its override keeps it
    /// there.
    fn write(&self, engine: &Engine, scripts: Vec<Json>, done: Done) {
        let environment = self.environment.clone();
        let project = self.project.clone();
        let me = self.me.clone();
        let finish = move |engine: &Engine, error: Option<String>| {
            me.run(engine, move |c, engine| done(c, engine, error));
        };
        let own = self
            .settings
            .settings(&environment)
            .is_some_and(|s| scripts::override_of(&s, &project).is_some_and(Json::is_array));
        if !own {
            self.mc.call(
                &environment,
                "projects.mutate",
                json!({"type": "project.update", "projectId": project, "scripts": scripts}),
                Box::new(move |engine, result| finish(engine, result.err().map(|e| e.message))),
            );
            return;
        }
        let finish = Rc::new(RefCell::new(Some(finish)));
        let later = finish.clone();
        let (edited, told) = (environment.clone(), environment.clone());
        let edit: Edit = Rc::new(move |document, environment_id| {
            let Json::Object(settings) = document else {
                return document;
            };
            if environment_id != edited {
                return Json::Object(settings);
            }
            Json::Object(SettingsScope::with_override(
                settings,
                &project,
                SCRIPTS,
                Some(Json::Array(scripts.clone())),
            ))
        });
        let started = self.settings.change(edit, move |engine, outcome| {
            if let Some(finish) = later.borrow_mut().take() {
                finish(engine, outcome.failed.get(&told).cloned());
            }
        });
        // Nothing to wait for: said once this has returned.
        if let Err(outcome) = started
            && let Some(finish) = finish.borrow_mut().take()
        {
            let error = outcome
                .failed
                .get(&environment)
                .cloned()
                .unwrap_or_else(|| "Not connected.".into());
            self.bridge
                .defer(engine, move |engine| finish(engine, Some(error)));
        }
    }

    /// Moves the action's shortcut to `key`, or drops it when empty and no
    /// other project of the environment has an action of that id.
    fn bind(&self, engine: &Engine, script_id: &str, key: &str) {
        let previous = self.shortcut_of(engine, script_id);
        if key == previous {
            return;
        }
        let environment = self.environment.clone();
        let told = |engine: &Engine, result: Result<Json, crate::mc::McError>| {
            if let Err(error) = result {
                error_toast(engine, SAVE_FAILED, &error.message);
            }
        };
        if !key.is_empty() {
            let mut rule = json!({"key": key, "command": command(script_id)});
            if !previous.is_empty() {
                rule["replace"] = json!({"key": previous, "command": command(script_id)});
            }
            self.mc.call(
                &environment,
                "hal-c2.upsertKeybinding",
                rule,
                Box::new(told),
            );
            return;
        }
        // Another project's action of the same id still runs from it.
        let elsewhere = rows_scripts(engine, &environment)
            .iter()
            .filter(|(id, _)| *id != self.project)
            .any(|(_, scripts)| scripts.iter().any(|s| text(s, "id") == script_id));
        if elsewhere {
            return;
        }
        self.mc.call(
            &environment,
            "hal-c2.removeKeybinding",
            json!({"key": previous, "command": command(script_id)}),
            Box::new(told),
        );
    }

    // -- Settings → Project -----------------------------------------------

    /// The scope's targets that keep lists, with their settings. At project
    /// scope only the environments whose server keeps project overrides.
    fn settings_targets(&self, engine: &Engine) -> Vec<Target> {
        let scope = SettingsScope::of(engine);
        let project = scope.project_scope();
        let old = if project {
            scope.lacking("projectSettingsOverrides")
        } else {
            Vec::new()
        };
        scope
            .targets()
            .into_iter()
            .filter(|id| !old.contains(id))
            .filter_map(|id| {
                let settings = scope.settings(&id)?;
                Some(Target {
                    project_id: if project {
                        scope.project_on(&id)
                    } else {
                        String::new()
                    },
                    environment_id: id,
                    settings: Json::Object(settings),
                })
            })
            .collect()
    }

    fn scripts_on(&self, engine: &Engine, target: &Target) -> Vec<Json> {
        if target.project_id.is_empty() {
            return target
                .settings
                .get(SCRIPTS)
                .and_then(Json::as_array)
                .cloned()
                .unwrap_or_default();
        }
        scripts::resolve(
            &target.settings,
            &target.project_id,
            &row_scripts(engine, &target.environment_id, &target.project_id),
        )
    }

    fn handle_settings(&mut self, engine: &Engine, action: &str, input: &Json) {
        let scope = SettingsScope::of(engine);
        let taken = |c: &ProjectActions| -> HashSet<String> {
            let mut ids = HashSet::new();
            for target in c.settings_targets(engine) {
                for script in c.scripts_on(engine, &target) {
                    ids.insert(text(&script, "id").to_owned());
                }
                for script in target
                    .settings
                    .get(SCRIPTS)
                    .and_then(Json::as_array)
                    .map(Vec::as_slice)
                    .unwrap_or_default()
                {
                    ids.insert(text(script, "id").to_owned());
                }
            }
            ids
        };
        match action {
            ADD => {
                let name = text(input, "name").trim().to_owned();
                let command_line = text(input, "command").trim().to_owned();
                if name.is_empty() || command_line.is_empty() {
                    return;
                }
                let icon = text(input, "icon");
                let script = Script {
                    icon: if file::ICONS.contains(&icon) {
                        icon.to_owned()
                    } else {
                        "play".to_owned()
                    },
                    run_on_worktree_create: flag(input, "runOnWorktreeCreate"),
                    r#async: None,
                    preview_url: text(input, "previewUrl").trim().to_owned(),
                    auto_open_preview: flag(input, "autoOpenPreview"),
                    name,
                    command: command_line,
                };
                let next = to_script(&script, &next_id(&script.name, &taken(self)));
                self.write_settings(
                    engine,
                    Rc::new(move |scripts| Some(appended(scripts, next.clone()))),
                    SAVE_FAILED,
                );
            }
            "projectActions.delete" => {
                let id = text(input, "scriptId").to_owned();
                if id.is_empty() {
                    return;
                }
                self.write_settings(
                    engine,
                    Rc::new(move |mut scripts| {
                        scripts.retain(|s| text(s, "id") != id);
                        Some(scripts)
                    }),
                    SAVE_FAILED,
                );
            }
            "projectActions.reset" => {
                // No list of its own: the environment's defaults again.
                if scope.project_scope() {
                    self.write_settings(engine, Rc::new(|_| None), SAVE_FAILED);
                }
            }
            "projectActions.import" => {
                let name = text(input, "name");
                let mut ids = taken(self);
                let mut added = Vec::new();
                for script in self.importable(engine) {
                    if !name.is_empty() && script.name != name {
                        continue;
                    }
                    let id = next_id(&script.name, &ids);
                    ids.insert(id.clone());
                    added.push(to_script(&script, &id));
                }
                if added.is_empty() {
                    return;
                }
                self.write_settings(
                    engine,
                    Rc::new(move |scripts| {
                        Some(
                            added
                                .iter()
                                .fold(scripts, |scripts, script| appended(scripts, script.clone())),
                        )
                    }),
                    "Failed to import action.",
                );
            }
            _ => {}
        }
    }

    /// Applies `transform` to each target's list; none drops a project's own
    /// list.
    fn write_settings(
        &self,
        engine: &Engine,
        transform: Rc<dyn Fn(Vec<Json>) -> Option<Vec<Json>>>,
        failure_title: &str,
    ) {
        let targets = self.settings_targets(engine);
        if targets.is_empty() {
            error_toast(
                engine,
                "Actions not saved",
                "No available machine, or another action change is saving.",
            );
            return;
        }
        // What each project's list is now, by its id on its environment.
        let current: HashMap<String, Vec<Json>> = targets
            .iter()
            .map(|t| (t.project_id.clone(), self.scripts_on(engine, t)))
            .collect();
        let project = SettingsScope::of(engine).project_scope();
        SettingsScope::of(engine).write(
            engine,
            move |mut settings: Map, project_id| {
                if project {
                    // An environment left out (too old for overrides) is not
                    // written to.
                    let Some(list) = current.get(project_id) else {
                        return settings;
                    };
                    return SettingsScope::with_override(
                        settings,
                        project_id,
                        SCRIPTS,
                        transform(list.clone()).map(Json::Array),
                    );
                }
                let list = settings
                    .get(SCRIPTS)
                    .and_then(Json::as_array)
                    .cloned()
                    .unwrap_or_default();
                settings.insert(
                    SCRIPTS.into(),
                    Json::Array(transform(list).unwrap_or_default()),
                );
                settings
            },
            failure_title,
        );
    }

    fn settings_state(&self, engine: &Engine) -> Json {
        let scope = SettingsScope::of(engine);
        let targets = self.settings_targets(engine);
        let listed = targets
            .first()
            .map(|t| self.scripts_on(engine, t))
            .unwrap_or_default();
        let project = scope.project_scope();
        let mut mixed = false;
        let mut own = false;
        for target in &targets {
            mixed = mixed || self.scripts_on(engine, target) != listed;
            own = own
                || (project
                    && !scripts::inherits(
                        &target.settings,
                        &target.project_id,
                        &row_scripts(engine, &target.environment_id, &target.project_id),
                    ));
        }
        let imports: Vec<Json> = self.importable(engine).iter().map(import_json).collect();
        json!({
            "settings": true,
            "projectKey": scope.project_key(),
            "project": project,
            "available": !targets.is_empty(),
            "scripts": self.script_rows(engine, &listed, true),
            "mixed": mixed,
            "own": own,
            "editor": Json::Null,
            "file": self.file_status,
            "imports": imports,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn taken(ids: &[&str]) -> HashSet<String> {
        ids.iter().map(|id| (*id).to_owned()).collect()
    }

    #[test]
    fn an_id_is_the_name_in_lower_case_with_dashes() {
        let none = taken(&[]);
        assert_eq!(next_id("Run Tests", &none), "run-tests");
        assert_eq!(next_id("  --Lint!!  all--  ", &none), "lint-all");
        assert_eq!(next_id("!!!", &none), "script");
        assert_eq!(next_id("", &none), "script");
    }

    #[test]
    fn an_id_is_at_most_24_characters_and_ends_in_a_letter() {
        let id = next_id("a very long action name that goes on", &taken(&[]));
        assert!(id.len() <= MAX_ID_LENGTH);
        assert!(!id.ends_with('-'));
        assert_eq!(id, "a-very-long-action-name");
    }

    #[test]
    fn a_taken_id_is_numbered_within_the_limit() {
        assert_eq!(next_id("Test", &taken(&["test"])), "test-2");
        assert_eq!(next_id("Test", &taken(&["test", "test-2"])), "test-3");
        let long = next_id("abcdefghijklmnopqrstuvwxyz", &taken(&[]));
        assert_eq!(long.len(), MAX_ID_LENGTH);
        let second = next_id("abcdefghijklmnopqrstuvwxyz", &taken(&[long.as_str()]));
        assert_eq!(second.len(), MAX_ID_LENGTH);
        assert!(second.ends_with("-2"));
    }

    #[test]
    fn one_action_is_the_setup_script() {
        let list = vec![
            json!({"id": "a", "runOnWorktreeCreate": true}),
            json!({"id": "b", "runOnWorktreeCreate": false}),
        ];
        let next = json!({"id": "c", "runOnWorktreeCreate": true});
        let result = appended(list.clone(), next);
        assert_eq!(
            result
                .iter()
                .filter(|s| flag(s, "runOnWorktreeCreate"))
                .count(),
            1
        );
        assert_eq!(text(&result[2], "id"), "c");
        let result = appended(list, json!({"id": "c"}));
        assert!(flag(&result[0], "runOnWorktreeCreate"));
    }

    #[test]
    fn an_imported_script_keeps_what_the_file_says() {
        let script = Script {
            name: "Dev".into(),
            command: "bun dev".into(),
            icon: "play".into(),
            run_on_worktree_create: true,
            r#async: Some(false),
            preview_url: "http://localhost:3000".into(),
            auto_open_preview: true,
        };
        let json = to_script(&script, "dev");
        assert_eq!(json["async"], false);
        assert_eq!(json["previewUrl"], "http://localhost:3000");
        assert_eq!(json["autoOpenPreview"], true);
        let plain = Script {
            run_on_worktree_create: false,
            r#async: Some(false),
            preview_url: String::new(),
            ..script
        };
        let json = to_script(&plain, "dev");
        assert!(json.get("async").is_none());
        assert!(json.get("previewUrl").is_none());
    }
}
