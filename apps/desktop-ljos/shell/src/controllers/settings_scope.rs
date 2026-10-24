//! `settingsScope`, desktop-qt's SettingsScopeController: where the
//! settings sections that edit environments' settings apply. That is all
//! projects or one logical project, across every environment or on one. A
//! change is written to every connected environment in the scope. A
//! project's change goes to its `projectSettingsOverrides` entry on each
//! environment with a checkout of it. The environments' documents are
//! followed while a settings page shows.
//!
//! Publishes `settingsScope`: {kind: all | environment | project |
//! unavailable, projectKey, environmentId ("" for all), projectLabel,
//! environmentLabel, connective ("across" | "on"), message (why the scope
//! is unavailable), projects [{key, title}], environments [{id, label,
//! online}], editable, and why not: disabledReason}.
//!
//! Actions: `settingsScope.project {key}` ("" for all projects) and
//! `settingsScope.environment {id}` ("" for all environments); each keeps
//! the other axis.
//!
//! Sections read and write through [`SettingsScope::of`]:
//!
//! ```ignore
//! let scope = SettingsScope::of(engine);
//! scope.read(|settings, project_id| ...);
//! scope.write(engine, |settings, project_id| settings, "");
//! ```
//!
//! What the cluster holds comes from the store and the sidebar's groups, or
//! from [`SettingsScope::set_sources`] (tests).

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init};
use crate::controllers::settings::{Map, Settings};
use crate::controllers::sidebar;
use crate::controllers::toasts::{DEFAULT_TIMEOUT_MS, Toasts};
use crate::environment_settings::{EnvironmentSettings, Outcome, Reading};
use crate::json::Json;
use crate::store;

const KEY: &str = "settingsScope";

/// The sections that edit environments' settings, which follow the scope.
/// General's rows of the MC count too; "" is General.
const SCOPED_SECTIONS: [&str; 8] = [
    "/settings/storage",
    "/settings/source-control",
    "/settings/projects",
    "/settings/scheduled-tasks",
    "/settings/integrations",
    "/settings/general",
    "/settings",
    "",
];

pub const RECONNECT: &str = "Reconnect the selected environment to change this setting.";

/// An environment of the cluster, as the store knows it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Environment {
    pub id: String,
    /// Empty: "This machine" for the MC's own, else the id.
    pub label: String,
    /// The store's last word. The scope also needs the shell's own
    /// connection up.
    pub online: bool,
}

/// A logical project as the sidebar groups it: its checkouts, by
/// environment.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ProjectGroup {
    pub key: String,
    pub title: String,
    /// The keys of the projects grouped, which outlive a regrouping.
    pub member_keys: Vec<String>,
    /// (environment id, project id) of each checkout.
    pub members: Vec<(String, String)>,
}

pub type Environments = Rc<dyn Fn(&Engine) -> Vec<Environment>>;
pub type Groups = Rc<dyn Fn(&Engine) -> Vec<ProjectGroup>>;
type Hook = Rc<dyn Fn(&Engine)>;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct Resolved {
    kind: &'static str,
    message: &'static str,
    /// The selected environments, connected or not, and by environment
    /// the project's checkout there.
    environments: Vec<String>,
    members: HashMap<String, String>,
}

impl Resolved {
    fn unavailable(message: &'static str) -> Resolved {
        Resolved {
            kind: "unavailable",
            message,
            ..Resolved::default()
        }
    }
}

#[derive(Default)]
struct State {
    active: bool,
    open: bool,
    project_key: String,
    environment_id: String,
    /// The picked project's member keys when it was last found, so a
    /// regrouping that renames its key keeps it picked.
    followed: Vec<String>,
    members: HashMap<String, String>,
    capabilities: HashMap<String, Map>,
    providers: HashMap<String, Vec<Json>>,
}

#[derive(Default)]
struct Inner {
    state: RefCell<State>,
    documents: RefCell<Option<Rc<EnvironmentSettings>>>,
    environments: RefCell<Option<Environments>>,
    groups: RefCell<Option<Groups>>,
    changed: RefCell<Vec<Hook>>,
}

#[derive(Default)]
struct Slot(RefCell<Option<SettingsScope>>);

/// The scope, from Rust: a handle, cheap to clone.
#[derive(Clone, Default)]
pub struct SettingsScope(Rc<Inner>);

impl std::fmt::Debug for SettingsScope {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let s = self.0.state.borrow();
        f.debug_struct("SettingsScope")
            .field("project", &s.project_key)
            .field("environment", &s.environment_id)
            .finish_non_exhaustive()
    }
}

impl SettingsScope {
    pub fn of(engine: &Engine) -> SettingsScope {
        let slot = Bridge::of(engine).extension::<Slot>(engine);
        if let Some(scope) = slot.0.borrow().clone() {
            return scope;
        }
        let scope = SettingsScope::default();
        *slot.0.borrow_mut() = Some(scope.clone());
        scope
    }

    /// Where the cluster's environments and the sidebar's projects come
    /// from; the scope updates now and whenever [`SettingsScope::refresh`]
    /// is called.
    pub fn set_sources(&self, engine: &Engine, environments: Environments, groups: Groups) {
        *self.0.environments.borrow_mut() = Some(environments);
        *self.0.groups.borrow_mut() = Some(groups);
        self.update(engine);
    }

    /// The store or the sidebar changed: what the scope covers may have.
    pub fn refresh(&self, engine: &Engine) {
        self.update(engine);
    }

    /// The scope, or a target's settings, changed. Runs once no controller
    /// is running.
    pub fn on_changed(&self, f: impl Fn(&Engine) + 'static) {
        self.0.changed.borrow_mut().push(Rc::new(f));
    }

    fn documents(&self, engine: &Engine) -> Option<Rc<EnvironmentSettings>> {
        if let Some(documents) = self.0.documents.borrow().clone() {
            return Some(documents);
        }
        let documents = Rc::new(EnvironmentSettings::new(controller::mc(engine)?));
        let me = Rc::downgrade(&self.0);
        documents.on_frame(move |engine, environment, frame| {
            let Some(inner) = me.upgrade() else { return };
            let config = frame.get("config");
            let providers = match frame.get("t").and_then(Json::as_str) {
                Some("config.providers") => frame.get("providers"),
                Some("config") => config.and_then(|c| c.get("providers")),
                _ => return,
            };
            let providers = providers
                .and_then(Json::as_array)
                .cloned()
                .unwrap_or_default();
            let only_providers = frame.get("t").and_then(Json::as_str) == Some("config.providers");
            {
                let mut s = inner.state.borrow_mut();
                s.providers.insert(environment.to_owned(), providers);
                if !only_providers {
                    let capabilities = config
                        .and_then(|c| c.get("environment"))
                        .and_then(|e| e.get("capabilities"))
                        .and_then(Json::as_object)
                        .cloned()
                        .unwrap_or_default();
                    s.capabilities.insert(environment.to_owned(), capabilities);
                }
            }
            // A providers frame brings no settings, so the documents say
            // nothing of it; a `config` frame's change comes from them.
            if only_providers {
                SettingsScope(inner).changed(engine);
            }
        });
        let me = Rc::downgrade(&self.0);
        documents.on_changed(move |engine| {
            if let Some(inner) = me.upgrade() {
                let scope = SettingsScope(inner);
                scope.publish(engine);
                scope.changed(engine);
            }
        });
        *self.0.documents.borrow_mut() = Some(documents.clone());
        Some(documents)
    }

    fn changed(&self, engine: &Engine) {
        Settings::of(engine).scope_changed(engine);
        let hooks = self.0.changed.borrow().clone();
        let bridge = Bridge::of(engine);
        for hook in hooks {
            bridge.defer(engine, move |engine| hook(engine));
        }
    }

    fn activate(&self, engine: &Engine) {
        if std::mem::replace(&mut self.0.state.borrow_mut().active, true) {
            return;
        }
        let bridge = Bridge::of(engine);
        let me = Rc::downgrade(&self.0);
        bridge.watch(engine, "route", move |engine, route| {
            if let Some(inner) = me.upgrade() {
                SettingsScope(inner).follow_route(engine, route);
            }
        });
        let route = bridge.published(engine, "route").unwrap_or(Json::Null);
        self.follow_route(engine, &route);
    }

    fn follow_route(&self, engine: &Engine, route: &Json) {
        let section = route
            .get("section")
            .and_then(Json::as_str)
            .unwrap_or_default();
        // Bare /settings shows General.
        let open = route.get("kind").and_then(Json::as_str) == Some("settings")
            && SCOPED_SECTIONS.contains(&section);
        self.0.state.borrow_mut().open = open;
        self.update(engine);
    }

    fn handle(&self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !self.0.state.borrow().active || !action.starts_with("settingsScope.") {
            return false;
        }
        let text = |key: &str| {
            payload
                .get(key)
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        {
            let mut s = self.0.state.borrow_mut();
            match action {
                "settingsScope.project" => {
                    s.project_key = text("key");
                    s.followed.clear();
                }
                "settingsScope.environment" => s.environment_id = text("id"),
                _ => return true,
            }
        }
        self.update(engine);
        true
    }

    // -- What the scope covers -----------------------------------------

    fn local(engine: &Engine) -> String {
        controller::mc(engine).map_or_else(String::new, |mc| mc.environment())
    }

    /// The cluster's environments, as the store says.
    fn known(&self, engine: &Engine) -> Vec<Environment> {
        let source = self.0.environments.borrow().clone();
        match source {
            Some(source) => source(engine),
            // The store's, else the MC's own before it has any.
            None => {
                let known: Vec<Environment> = store::with(engine, |s| {
                    s.environments()
                        .into_iter()
                        .map(|id| Environment {
                            label: s
                                .environment(&id)
                                .get("label")
                                .and_then(Json::as_str)
                                .unwrap_or_default()
                                .to_owned(),
                            online: s.environment_online(&id),
                            id,
                        })
                        .collect()
                });
                let local = SettingsScope::local(engine);
                if !known.is_empty() || local.is_empty() {
                    known
                } else {
                    vec![Environment {
                        id: local,
                        label: String::new(),
                        online: true,
                    }]
                }
            }
        }
    }

    fn groups(&self, engine: &Engine) -> Vec<ProjectGroup> {
        let source = self.0.groups.borrow().clone();
        match source {
            Some(source) => source(engine),
            None => sidebar::groups(engine)
                .into_iter()
                .map(|g| ProjectGroup {
                    title: g
                        .summary
                        .get("displayName")
                        .and_then(Json::as_str)
                        .unwrap_or_default()
                        .to_owned(),
                    key: g.key,
                    member_keys: g.member_keys,
                    members: g
                        .members
                        .into_iter()
                        .map(|p| (p.environment_id, p.id))
                        .collect(),
                })
                .collect(),
        }
    }

    pub fn label(&self, engine: &Engine, environment_id: &str) -> String {
        if let Some(e) = self
            .known(engine)
            .into_iter()
            .find(|e| e.id == environment_id)
            && !e.label.is_empty()
        {
            return e.label;
        }
        if environment_id == SettingsScope::local(engine) {
            "This machine".into()
        } else {
            environment_id.into()
        }
    }

    /// Every environment of the cluster, whatever the scope: the shell's
    /// own first, the others by name.
    pub fn listed(&self, engine: &Engine) -> Vec<String> {
        let local = SettingsScope::local(engine);
        let mut ids: Vec<(String, String)> = Vec::new();
        for e in self.known(engine) {
            if !ids.iter().any(|(id, _)| *id == e.id) {
                let label = self.label(engine, &e.id).to_lowercase();
                ids.push((e.id, label));
            }
        }
        ids.sort_by(|(a, la), (b, lb)| {
            (*b == local)
                .cmp(&(*a == local))
                .then_with(|| crate::sidebar_model::locale_compare(la, lb))
        });
        ids.into_iter().map(|(id, _)| id).collect()
    }

    /// The store keeps its last word on each environment while the shell's
    /// own connection is down; none is reachable then.
    pub fn online(&self, engine: &Engine, environment_id: &str) -> bool {
        controller::mc(engine).is_some_and(|mc| mc.is_ready())
            && self
                .known(engine)
                .iter()
                .any(|e| e.id == environment_id && e.online)
    }

    /// resolveSettingsScope: a selection that no longer exists is
    /// unavailable, and never broadens to everything.
    fn resolve(&self, engine: &Engine) -> Resolved {
        let environments = self.listed(engine);
        let (project_key, environment_id) = {
            let s = self.0.state.borrow();
            (s.project_key.clone(), s.environment_id.clone())
        };
        if !environment_id.is_empty() && !environments.contains(&environment_id) {
            return Resolved::unavailable("This environment is no longer available.");
        }
        if !project_key.is_empty() {
            let groups = self.groups(engine);
            let Some(group) = groups.iter().find(|g| g.key == project_key) else {
                return Resolved::unavailable("This project is no longer available.");
            };
            let mut resolved = Resolved {
                kind: "project",
                ..Resolved::default()
            };
            for (environment, project) in &group.members {
                if !environment_id.is_empty() && *environment != environment_id {
                    continue;
                }
                if !environments.contains(environment) || resolved.members.contains_key(environment)
                {
                    continue;
                }
                resolved
                    .members
                    .insert(environment.clone(), project.clone());
                resolved.environments.push(environment.clone());
            }
            if resolved.environments.is_empty() {
                return Resolved::unavailable("This project has no checkout on this environment.");
            }
            return resolved;
        }
        Resolved {
            kind: if environment_id.is_empty() {
                "all"
            } else {
                "environment"
            },
            environments: if environment_id.is_empty() {
                environments
            } else {
                vec![environment_id]
            },
            ..Resolved::default()
        }
    }

    fn update(&self, engine: &Engine) {
        if !self.0.state.borrow().active {
            return;
        }
        // The picked project follows its members when grouping gives it a
        // new key (useSettingsProjectGroups); one removed everywhere stays
        // unavailable.
        let project_key = self.0.state.borrow().project_key.clone();
        if !project_key.is_empty() {
            let groups = self.groups(engine);
            let mut s = self.0.state.borrow_mut();
            if let Some(group) = groups.iter().find(|g| g.key == project_key) {
                s.followed = group.member_keys.clone();
            } else if let Some(group) = groups
                .iter()
                .find(|g| g.member_keys.iter().any(|k| s.followed.contains(k)))
            {
                s.project_key = group.key.clone();
                s.followed = group.member_keys.clone();
            }
        }
        let resolved = self.resolve(engine);
        let open = {
            let mut s = self.0.state.borrow_mut();
            s.members = resolved.members.clone();
            s.open
        };
        let targets: Vec<String> = if open {
            resolved
                .environments
                .iter()
                .filter(|id| self.online(engine, id))
                .cloned()
                .collect()
        } else {
            Vec::new()
        };
        if let Some(documents) = self.documents(engine) {
            documents.set_targets(&targets);
        }
        self.publish(engine);
        self.changed(engine);
    }

    // -- Reading and writing ---------------------------------------------

    pub fn project_scope(&self) -> bool {
        !self.0.state.borrow().project_key.is_empty()
    }

    /// The logical project picked ("" for all projects).
    pub fn project_key(&self) -> String {
        self.0.state.borrow().project_key.clone()
    }

    /// The environment picked ("" for all environments).
    pub fn environment_filter(&self) -> String {
        self.0.state.borrow().environment_id.clone()
    }

    /// The connected environments a change is written to, in reading
    /// order.
    pub fn targets(&self) -> Vec<String> {
        self.0
            .documents
            .borrow()
            .as_ref()
            .map_or_else(Vec::new, |d| d.targets())
    }

    pub fn settings(&self, environment_id: &str) -> Option<Map> {
        let documents = self.0.documents.borrow().clone()?;
        match documents.settings(environment_id)? {
            Json::Object(settings) => Some(settings),
            _ => None,
        }
    }

    /// A target's providers (ServerConfig providers), as its config frames
    /// last said.
    pub fn providers(&self, environment_id: &str) -> Vec<Json> {
        self.0
            .state
            .borrow()
            .providers
            .get(environment_id)
            .cloned()
            .unwrap_or_default()
    }

    /// The connected targets whose environment lacks the capability
    /// (ServerConfig environment.capabilities).
    pub fn lacking(&self, capability: &str) -> Vec<String> {
        let s = self.0.state.borrow();
        self.targets()
            .into_iter()
            .filter(|id| self.settings(id).is_some())
            .filter(|id| {
                s.capabilities.get(id).and_then(|c| c.get(capability)) != Some(&Json::Bool(true))
            })
            .collect()
    }

    /// The scope's kind: all, environment, project or unavailable.
    pub fn kind(&self, engine: &Engine) -> &'static str {
        self.resolve(engine).kind
    }

    /// The scope's environments, connected or not ("unavailable" has none).
    pub fn environments(&self, engine: &Engine) -> Vec<String> {
        self.resolve(engine).environments
    }

    /// For a project scope its checkout on the environment ("" otherwise).
    pub fn project_on(&self, environment_id: &str) -> String {
        self.0
            .state
            .borrow()
            .members
            .get(environment_id)
            .cloned()
            .unwrap_or_default()
    }

    /// Whether a project of the environment is in the scope.
    pub fn covers(&self, engine: &Engine, environment_id: &str, project_id: &str) -> bool {
        let resolved = self.resolve(engine);
        resolved.environments.iter().any(|e| e == environment_id)
            && (resolved.kind != "project"
                || resolved.members.get(environment_id).map(String::as_str) == Some(project_id))
    }

    /// `pick` of each target's document, with the project's checkout there
    /// for a project scope ("" otherwise).
    pub fn read(&self, pick: impl Fn(&Map, &str) -> Option<Json>) -> Reading {
        let Some(documents) = self.0.documents.borrow().clone() else {
            return Reading::default();
        };
        let members = self.0.state.borrow().members.clone();
        documents.read(&|settings, environment| {
            pick(
                settings.as_object()?,
                members.get(environment).map_or("", String::as_str),
            )
        })
    }

    pub fn editable(&self, engine: &Engine) -> bool {
        self.disabled_reason(engine).is_empty()
    }

    pub fn disabled_reason(&self, engine: &Engine) -> String {
        let resolved = self.resolve(engine);
        if resolved.kind == "unavailable" {
            return resolved.message.to_owned();
        }
        // A page that edits no settings (Archive only narrows a list) has
        // nothing to reconnect.
        if !self.0.state.borrow().open {
            return String::new();
        }
        if self.targets().is_empty() {
            return RECONNECT.to_owned();
        }
        String::new()
    }

    /// Changes every target. A failure is toasted with the environments
    /// that could not save, titled `failure_title` when given. Nothing is
    /// written while the scope is not editable.
    pub fn write(
        &self,
        engine: &Engine,
        edit: impl Fn(Map, &str) -> Map + 'static,
        failure_title: &str,
    ) {
        let reason = self.disabled_reason(engine);
        let failure_title = failure_title.to_owned();
        if !reason.is_empty() {
            let title = if failure_title.is_empty() {
                "Setting not saved".to_owned()
            } else {
                failure_title
            };
            Bridge::of(engine).defer(engine, move |engine| {
                controller::with::<Toasts, _>(engine, |toasts, engine| {
                    toasts.show(engine, "warning", &title, &reason, None, DEFAULT_TIMEOUT_MS);
                });
            });
            return;
        }
        let Some(documents) = self.documents(engine) else {
            return;
        };
        let members = self.0.state.borrow().members.clone();
        let me = Rc::downgrade(&self.0);
        let failed = move |engine: &Engine, outcome: Outcome| {
            let Some(inner) = me.upgrade() else { return };
            let Outcome { failed, saved } = outcome;
            if failed.is_empty() {
                return;
            }
            let scope = SettingsScope(inner);
            let labels: Vec<String> = scope
                .targets()
                .iter()
                .filter(|id| failed.contains_key(*id))
                .map(|id| scope.label(engine, id))
                .collect();
            let title = if !failure_title.is_empty() {
                failure_title
            } else if saved > 0 {
                "Setting saved on some environments".to_owned()
            } else {
                "Setting not saved".to_owned()
            };
            let others = if saved > 0 {
                " The other selected environments saved the change."
            } else {
                ""
            };
            let description = format!("Could not update {}.{others}", labels.join(", "));
            Bridge::of(engine).defer(engine, move |engine| {
                controller::with::<Toasts, _>(engine, |toasts, engine| {
                    toasts.error(engine, &title, &description);
                });
            });
        };
        let failed = Rc::new(RefCell::new(Some(failed)));
        let later = failed.clone();
        let edit = Rc::new(move |settings: Json, environment: &str| {
            let settings = match settings {
                Json::Object(settings) => settings,
                _ => Map::new(),
            };
            Json::Object(edit(
                settings,
                members.get(environment).map_or("", String::as_str),
            ))
        });
        let started = documents.change(edit, move |engine, outcome| {
            if let Some(failed) = later.borrow_mut().take() {
                failed(engine, outcome);
            }
        });
        // No target could be written: said at once.
        if let Err(outcome) = started
            && let Some(failed) = failed.borrow_mut().take()
        {
            failed(engine, outcome);
        }
    }

    /// `settings` with the project's override of `key` set; `None` removes
    /// it, and an override left empty goes.
    pub fn with_override(
        mut settings: Map,
        project_id: &str,
        key: &str,
        value: Option<Json>,
    ) -> Map {
        let mut overrides = settings
            .get("projectSettingsOverrides")
            .and_then(Json::as_object)
            .cloned()
            .unwrap_or_default();
        let mut entry = overrides
            .get(project_id)
            .and_then(Json::as_object)
            .cloned()
            .unwrap_or_default();
        match value {
            Some(value) => {
                entry.insert(key.to_owned(), value);
            }
            None => {
                entry.remove(key);
            }
        }
        if entry.is_empty() {
            overrides.remove(project_id);
        } else {
            overrides.insert(project_id.to_owned(), Json::Object(entry));
        }
        settings.insert("projectSettingsOverrides".into(), Json::Object(overrides));
        settings
    }

    pub fn override_of(settings: &Map, project_id: &str, key: &str) -> Option<Json> {
        settings
            .get("projectSettingsOverrides")?
            .get(project_id)?
            .get(key)
            .cloned()
    }

    fn publish(&self, engine: &Engine) {
        if !self.0.state.borrow().active {
            return;
        }
        let resolved = self.resolve(engine);
        let (project_key, environment_id) = {
            let s = self.0.state.borrow();
            (s.project_key.clone(), s.environment_id.clone())
        };
        let listed = self.listed(engine);
        let environments: Vec<Json> = listed
            .iter()
            .map(|id| json!({"id": id, "label": self.label(engine, id), "online": self.online(engine, id)}))
            .collect();
        let mut project_label = "All projects".to_owned();
        let mut projects = Vec::new();
        for group in self.groups(engine) {
            projects.push(json!({"key": group.key, "title": group.title}));
            if group.key == project_key {
                project_label = group.title;
            }
        }
        if !project_key.is_empty() && project_label == "All projects" {
            project_label = "Unavailable project".into();
        }
        let environment_label = if environment_id.is_empty() {
            "All environments".to_owned()
        } else if listed.contains(&environment_id) {
            self.label(engine, &environment_id)
        } else {
            "Unavailable environment".to_owned()
        };
        let reason = self.disabled_reason(engine);
        Bridge::of(engine).publish(
            engine,
            KEY,
            json!({
                "kind": resolved.kind,
                "projectKey": project_key,
                "environmentId": environment_id,
                "projectLabel": project_label,
                "environmentLabel": environment_label,
                "connective": if environment_id.is_empty() { "across" } else { "on" },
                "message": resolved.message,
                "projects": projects,
                "environments": environments,
                "editable": reason.is_empty(),
                "disabledReason": reason,
            }),
        );
    }
}

/// The controller: activates the scope and takes its actions. Everything
/// else is [`SettingsScope`].
pub struct SettingsScopeController {
    scope: SettingsScope,
}

impl Controller for SettingsScopeController {
    fn new(init: Init<'_, Self>) -> Self {
        init.mc.on_ready_changed(Box::new(|engine: &Engine, _| {
            SettingsScope::of(engine).update(engine);
        }));
        // What the scope covers follows the cluster and the sidebar's
        // grouping.
        let refresh = |engine: &Engine| {
            Bridge::of(engine).defer(engine, |engine| SettingsScope::of(engine).refresh(engine));
        };
        store::on_changed(init.engine, refresh);
        sidebar::on_grouped(init.engine, refresh);
        SettingsScopeController {
            scope: SettingsScope::of(init.engine),
        }
    }

    fn activate(&mut self, engine: &Engine) {
        self.scope.activate(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        self.scope.handle(engine, action, payload)
    }
}

impl SettingsScopeController {
    pub fn scope(&self) -> SettingsScope {
        self.scope.clone()
    }
}
