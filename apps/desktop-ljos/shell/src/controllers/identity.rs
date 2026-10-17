//! `identity`, desktop-qt's IdentityController: what tells projects and
//! environments apart at a glance.
//!
//! Publishes `projectIcons`: every project's icon by
//! `<environmentId>:<projectId>`, {kind (monogram | emoji | lucide | image),
//! text, emoji, name, color, tint, url (an image's, on the MC), path,
//! automatic}. A project with no icon of its own shows the monogram and
//! colour derived from its name until the MC serves a favicon for it
//! (`assets.createUrl` project-favicon): its own, or the image file the user
//! picked.
//!
//! The picker (ProjectIconPicker.qml), opened from Settings → Projects, is
//! `projectIconPicker`, null while closed: {name, mode (lucide | emoji |
//! monogram | image), symbol, color, tint, letters, emoji, error, symbols,
//! colors: [{name, tint}], query, searching, images: [paths]}. Actions:
//! `projectIcon.open {projectKey, name}`, `projectIcon.set {mode?, symbol?,
//! color?, letters?, emoji?}`, `projectIcon.search {query}` (image files of
//! the project only), `projectIcon.save` (a monogram must be one or two
//! letters or numbers), `projectIcon.image {path}` and `projectIcon.cancel`.
//! Saving goes through `projectSettings.icon`, which writes every checkout in
//! the settings' scope.
//!
//! Publishes `environmentIcons`: by environment, {kind (server | cloud |
//! linux | desktop | laptop | mac-mini | mac-studio), detected, icon (the
//! lucide name), label, chosen, lock (why it cannot be changed, or ""),
//! kinds: [{kind, label, icon}]}. `environmentIcon.set {environmentId, kind}`
//! saves the `environmentIcon` setting there; the detected kind clears it.
//! The session's own scopes come from the MC's `/api/auth/session`, asked
//! once an icon is about to change.

use std::collections::HashMap;
use std::rc::Rc;

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::toasts::Toasts;
use crate::environment_settings::{self, EnvironmentSettings, Outcome};
use crate::json::Json;
use crate::mc::{Mc, McError};
use crate::project::identity;
use crate::store;
use crate::thread_view::workspace_files::{self, SEARCH_LIMIT};

const PROJECT_ICONS: &str = "projectIcons";
const PICKER: &str = "projectIconPicker";
const ENVIRONMENT_ICONS: &str = "environmentIcons";

/// packages/contracts ENVIRONMENT_MACHINE_KINDS: each kind's label and the
/// lucide icon that stands for it.
struct Machine {
    kind: &'static str,
    label: &'static str,
    icon: &'static str,
}

const MACHINES: [Machine; 7] = [
    Machine {
        kind: "server",
        label: "Server",
        icon: "server",
    },
    Machine {
        kind: "cloud",
        label: "Cloud",
        icon: "cloud",
    },
    Machine {
        kind: "linux",
        label: "Linux",
        icon: "terminal",
    },
    Machine {
        kind: "desktop",
        label: "Desktop",
        icon: "monitor",
    },
    Machine {
        kind: "laptop",
        label: "Laptop",
        icon: "laptop",
    },
    Machine {
        kind: "mac-mini",
        label: "Mac mini",
        icon: "cpu",
    },
    Machine {
        kind: "mac-studio",
        label: "Mac Studio",
        icon: "cpu",
    },
];

fn machine(kind: &str) -> Option<&'static Machine> {
    MACHINES.iter().find(|m| m.kind == kind)
}

const MODES: [&str; 4] = ["lucide", "emoji", "monogram", "image"];

fn text<'a>(object: &'a Json, key: &str) -> &'a str {
    object.get(key).and_then(Json::as_str).unwrap_or_default()
}

/// `<environmentId>:<projectId>` split at its first colon.
fn split_key(key: &str) -> (&str, &str) {
    key.split_once(':').unwrap_or((key, ""))
}

struct Picker {
    project_key: String,
    name: String,
    mode: String,
    symbol: String,
    color: String,
    letters: String,
    emoji: String,
    error: String,
    query: String,
    searching: bool,
    images: Vec<String>,
    /// The search whose answer is wanted; an older one's is dropped.
    request: u64,
}

/// A project's favicon on its MC: what it was asked for (the checkout and
/// the picked file) and the URL that came, empty for none.
#[derive(Default)]
struct Favicon {
    asked: String,
    url: String,
}

/// What runs once the session's scopes are known.
type Then = Box<dyn FnOnce(&mut Identity, &Engine)>;

pub struct Identity {
    bridge: Bridge,
    me: Me<Identity>,
    mc: Rc<dyn Mc>,
    settings: EnvironmentSettings,
    active: bool,
    favicons: HashMap<String, Favicon>,
    project_icons: Option<Json>,
    picker: Option<Picker>,
    /// Each environment's `environment` descriptor from its config.
    descriptors: HashMap<String, Json>,
    environment_icons: Option<Json>,
    /// Whether this session may change the MC's own environment; unknown
    /// until asked.
    may_operate: Option<bool>,
}

impl Controller for Identity {
    fn new(init: Init<'_, Self>) -> Self {
        Identity {
            bridge: init.bridge,
            me: init.me,
            settings: EnvironmentSettings::new(init.mc.clone()),
            mc: init.mc,
            active: false,
            favicons: HashMap::new(),
            project_icons: None,
            picker: None,
            descriptors: HashMap::new(),
            environment_icons: None,
            may_operate: None,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let me = self.me.clone();
        store::on_changed(engine, move |engine| {
            me.run(engine, |c, engine| {
                c.refresh_projects(engine);
                c.refresh_environments(engine);
            });
        });
        let me = self.me.clone();
        self.settings.on_changed(move |engine| {
            me.run(engine, |c, engine| c.refresh_environments(engine));
        });
        let me = self.me.clone();
        self.settings
            .on_frame(move |engine, environment_id, frame| {
                if frame.get("t").and_then(Json::as_str) != Some("config") {
                    return;
                }
                let Some(descriptor) = frame
                    .get("config")
                    .and_then(|c| c.get("environment"))
                    .filter(|d| d.is_object())
                    .cloned()
                else {
                    return;
                };
                let environment_id = environment_id.to_owned();
                me.run(engine, move |c, engine| {
                    if c.descriptors.get(&environment_id) == Some(&descriptor) {
                        return;
                    }
                    c.descriptors.insert(environment_id, descriptor);
                    c.refresh_environments(engine);
                });
            });
        let me = self.me.clone();
        self.mc.on_ready_changed(Box::new(move |engine, ready| {
            me.run(engine, |c, engine| {
                // Another connection is another session.
                if !ready {
                    c.may_operate = None;
                }
                c.refresh_environments(engine);
            });
        }));
        self.refresh_projects(engine);
        self.refresh_environments(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if action == "environmentIcon.set" {
            let environment_id = text(payload, "environmentId").to_owned();
            let kind = text(payload, "kind").to_owned();
            self.with_session(
                engine,
                Box::new(move |c, engine| c.set_environment_kind(engine, &environment_id, &kind)),
            );
            return true;
        }
        match action {
            "projectIcon.open" => {
                self.open_picker(engine, text(payload, "projectKey"), text(payload, "name"))
            }
            "projectIcon.set" => self.set_picker(engine, payload),
            "projectIcon.search" => self.search(engine, text(payload, "query")),
            "projectIcon.save" => self.save_picker(engine),
            "projectIcon.image" => {
                let path = text(payload, "path");
                if self.picker.is_some() && identity::is_image(path) {
                    self.picker = None;
                    self.publish_picker(engine);
                    self.bridge.dispatch(
                        engine,
                        "projectSettings.icon",
                        json!({"faviconPath": path}),
                    );
                }
            }
            "projectIcon.cancel" => {
                self.picker = None;
                self.publish_picker(engine);
            }
            _ => return false,
        }
        true
    }
}

// --- Projects ------------------------------------------------------------------------

impl Identity {
    fn refresh_projects(&mut self, engine: &Engine) {
        let environments: Vec<(String, bool, Vec<Json>)> = store::with(engine, |s| {
            s.environments()
                .into_iter()
                .map(|id| {
                    let online = s.environment_online(&id);
                    let rows = s
                        .project_rows(&id)
                        .into_iter()
                        .map(|row| Json::Object(row.clone()))
                        .collect();
                    (id, online, rows)
                })
                .collect()
        });
        let mut icons = serde_json::Map::new();
        let mut asks = Vec::new();
        for (environment_id, online, rows) in environments {
            for row in rows {
                let key = format!("{environment_id}:{}", text(&row, "id"));
                let mut icon = identity::icon(&row);
                let own = row
                    .get("projectIcon")
                    .and_then(Json::as_object)
                    .is_some_and(|o| !o.is_empty());
                if own {
                    self.favicons.remove(&key);
                } else {
                    // Its own favicon, or the image the user picked, once the
                    // MC serves one.
                    let favicon_path = text(&row, "faviconPath");
                    let asked = format!("{}\n{favicon_path}", text(&row, "workspaceRoot"));
                    let stale = self.favicons.get(&key).is_none_or(|f| f.asked != asked);
                    if stale && online {
                        self.favicons.insert(
                            key.clone(),
                            Favicon {
                                asked: asked.clone(),
                                url: String::new(),
                            },
                        );
                        asks.push((key.clone(), asked, row.clone()));
                    }
                    if let Some(favicon) = self.favicons.get(&key).filter(|f| !f.url.is_empty()) {
                        icon = json!({
                            "kind": "image", "url": favicon.url, "path": favicon_path,
                            "automatic": favicon_path.is_empty(),
                        });
                    }
                }
                icons.insert(key, icon);
            }
        }
        self.favicons.retain(|key, _| icons.contains_key(key));
        for (key, asked, row) in asks {
            self.request_favicon(&key, asked, &row);
        }
        let icons = Json::Object(icons);
        if self.project_icons.as_ref() == Some(&icons) {
            return;
        }
        self.project_icons = Some(icons.clone());
        self.bridge.publish(engine, PROJECT_ICONS, icons);
    }

    fn request_favicon(&self, key: &str, asked: String, row: &Json) {
        let mut resource = json!({"_tag": "project-favicon", "cwd": text(row, "workspaceRoot")});
        let path = text(row, "faviconPath");
        if !path.is_empty() {
            resource["path"] = path.into();
        }
        let me = self.me.clone();
        let environment_id = split_key(key).0;
        let key = key.to_owned();
        self.mc.call(
            environment_id,
            "assets.createUrl",
            json!({"resource": resource}),
            Box::new(move |engine, result: Result<Json, McError>| {
                me.run(engine, move |c, engine| {
                    c.favicon_answered(engine, &key, &asked, result)
                });
            }),
        );
    }

    fn favicon_answered(
        &mut self,
        engine: &Engine,
        key: &str,
        asked: &str,
        result: Result<Json, McError>,
    ) {
        if self.favicons.get(key).is_none_or(|f| f.asked != asked) {
            return;
        }
        let relative = result
            .ok()
            .and_then(|r| {
                r.get("relativeUrl")
                    .and_then(Json::as_str)
                    .map(str::to_owned)
            })
            .unwrap_or_default();
        // The MC names a project without a favicon this way: the monogram stays.
        if relative.is_empty() || relative.ends_with("project-favicon-missing") {
            return;
        }
        let url = self
            .mc
            .origin()
            .and_then(|o| url::Url::parse(&o).ok())
            .and_then(|o| o.join(&relative).ok())
            .map_or(relative, |u| u.to_string());
        if let Some(favicon) = self.favicons.get_mut(key) {
            favicon.url = url;
        }
        self.refresh_projects(engine);
    }

    fn publish_picker(&self, engine: &Engine) {
        let state = match &self.picker {
            None => Json::Null,
            Some(p) => {
                let colors: Vec<Json> = identity::COLORS
                    .iter()
                    .map(|c| json!({"name": c, "tint": identity::tint(c)}))
                    .collect();
                json!({
                    "name": p.name, "mode": p.mode, "symbol": p.symbol, "color": p.color,
                    "tint": identity::tint(&p.color), "letters": p.letters, "emoji": p.emoji,
                    "error": p.error, "symbols": identity::SYMBOLS, "colors": colors,
                    "query": p.query, "searching": p.searching, "images": p.images,
                })
            }
        };
        self.bridge.publish(engine, PICKER, state);
    }

    fn open_picker(&mut self, engine: &Engine, project_key: &str, name: &str) {
        let (environment_id, project_id) = split_key(project_key);
        let Some(row) = store::with(engine, |s| {
            s.project_row(environment_id, project_id)
                .map(|r| Json::Object(r.clone()))
        }) else {
            return;
        };
        let name = if name.is_empty() {
            text(&row, "title")
        } else {
            name
        };
        let automatic = identity::derive(name);
        let current = identity::icon(&row);
        let mut picker = Picker {
            project_key: project_key.to_owned(),
            name: name.to_owned(),
            mode: "lucide".into(),
            symbol: "folder-code".into(),
            color: automatic.color.to_string(),
            letters: automatic.monogram.to_string(),
            emoji: "💻".into(),
            error: String::new(),
            query: String::new(),
            searching: false,
            images: Vec::new(),
            request: 0,
        };
        if current.get("automatic").and_then(Json::as_bool) != Some(true) {
            picker.mode = text(&current, "kind").to_owned();
            match picker.mode.as_str() {
                "lucide" => picker.symbol = text(&current, "name").to_owned(),
                "monogram" => picker.letters = text(&current, "text").to_owned(),
                "emoji" => picker.emoji = text(&current, "emoji").to_owned(),
                _ => {}
            }
            if picker.mode != "emoji" {
                picker.color = text(&current, "color").to_owned();
            }
        } else if !text(&row, "faviconPath").is_empty() {
            picker.mode = "image".into();
        }
        self.picker = Some(picker);
        self.publish_picker(engine);
    }

    fn set_picker(&mut self, engine: &Engine, fields: &Json) {
        let Some(picker) = &mut self.picker else {
            return;
        };
        let mode = text(fields, "mode");
        if MODES.contains(&mode) {
            picker.mode = mode.to_owned();
        }
        let symbol = text(fields, "symbol");
        if identity::SYMBOLS.contains(&symbol) {
            picker.symbol = symbol.to_owned();
        }
        let color = text(fields, "color");
        if identity::COLORS.contains(&color) {
            picker.color = color.to_owned();
        }
        if fields.get("letters").is_some() {
            picker.letters = text(fields, "letters").to_owned();
        }
        if fields.get("emoji").is_some() {
            picker.emoji = text(fields, "emoji").to_owned();
        }
        picker.error.clear();
        self.publish_picker(engine);
    }

    /// Image files only: what can be an icon.
    fn search(&mut self, engine: &Engine, query: &str) {
        let Some(picker) = &mut self.picker else {
            return;
        };
        picker.query = query.to_owned();
        picker.request += 1;
        let request = picker.request;
        let (environment_id, project_id) = split_key(&picker.project_key);
        let environment_id = environment_id.to_owned();
        let cwd = store::with(engine, |s| {
            s.project_row(&environment_id, project_id)
                .and_then(|r| r.get("workspaceRoot").and_then(Json::as_str))
                .map(str::to_owned)
        })
        .unwrap_or_default();
        let trimmed = query.trim().to_owned();
        if trimmed.is_empty() || cwd.is_empty() {
            picker.searching = false;
            picker.images.clear();
            self.publish_picker(engine);
            return;
        }
        picker.searching = true;
        self.publish_picker(engine);
        let me = self.me.clone();
        workspace_files::search_entries(
            &*self.mc,
            &environment_id,
            &cwd,
            &trimmed,
            SEARCH_LIMIT,
            move |engine, result| {
                me.run(engine, move |c, engine| {
                    let Some(picker) = c.picker.as_mut().filter(|p| p.request == request) else {
                        return;
                    };
                    picker.searching = false;
                    picker.images = result
                        .map(|(entries, _)| entries)
                        .unwrap_or_default()
                        .into_iter()
                        .filter(|e| !e.directory && identity::is_image(&e.path))
                        .map(|e| e.path)
                        .collect();
                    picker.images.sort();
                    c.publish_picker(engine);
                });
            },
        );
    }

    fn save_picker(&mut self, engine: &Engine) {
        let Some(picker) = &mut self.picker else {
            return;
        };
        let icon = match picker.mode.as_str() {
            "monogram" => {
                let letters = identity::monogram(&picker.letters);
                if !identity::valid_monogram(&letters) {
                    picker.error = "Use one or two letters or numbers.".into();
                    self.publish_picker(engine);
                    return;
                }
                identity::wire("monogram", &letters, &picker.color)
            }
            "emoji" => {
                let emoji = picker.emoji.trim();
                if emoji.is_empty() {
                    picker.error = "Choose an emoji.".into();
                    self.publish_picker(engine);
                    return;
                }
                identity::wire("emoji", emoji, "")
            }
            "lucide" => identity::wire("lucide", &picker.symbol, &picker.color),
            _ => {
                picker.error = "Choose an image file.".into();
                self.publish_picker(engine);
                return;
            }
        };
        self.picker = None;
        self.publish_picker(engine);
        self.bridge
            .dispatch(engine, "projectSettings.icon", json!({"icon": icon}));
    }
}

// --- Environments --------------------------------------------------------------------

impl Identity {
    fn detected(&self, environment_id: &str) -> &str {
        self.descriptors
            .get(environment_id)
            .and_then(|d| d.get("platform"))
            .map(|p| text(p, "machine"))
            .unwrap_or_default()
    }

    fn lock_of(&self, engine: &Engine, environment_id: &str) -> &'static str {
        let online = store::with(engine, |s| s.environment_online(environment_id));
        if !self.mc.is_ready() || !online || self.settings.settings(environment_id).is_none() {
            return "Connect to this environment to change its icon.";
        }
        let keeps_icons = self
            .descriptors
            .get(environment_id)
            .and_then(|d| environment_settings::at(d, "capabilities.environmentIcon"))
            == Some(&Json::Bool(true));
        if !keeps_icons {
            return "This environment's server is too old to keep an icon. Update it to choose one.";
        }
        let own = environment_id == self.mc.environment();
        if own && self.may_operate == Some(false) {
            return "Your session on this environment cannot change its settings.";
        }
        ""
    }

    fn refresh_environments(&mut self, engine: &Engine) {
        if !self.active {
            return;
        }
        let environments = store::with(engine, |s| s.environments());
        self.settings.set_targets(&environments);
        let kinds: Vec<Json> = MACHINES
            .iter()
            .map(|m| json!({"kind": m.kind, "label": m.label, "icon": m.icon}))
            .collect();
        let mut icons = serde_json::Map::new();
        for environment_id in environments {
            let detected = self.detected(&environment_id);
            let chosen = self
                .settings
                .settings(&environment_id)
                .map(|s| text(&s, "environmentIcon").to_owned())
                .unwrap_or_default();
            let shown = machine(&chosen)
                .or_else(|| machine(detected))
                .unwrap_or(&MACHINES[0]);
            let entry = json!({
                "kind": shown.kind, "label": shown.label, "icon": shown.icon,
                "detected": if machine(detected).is_some() { detected } else { "" },
                "chosen": machine(&chosen).is_some(),
                "lock": self.lock_of(engine, &environment_id),
                "kinds": kinds,
            });
            icons.insert(environment_id, entry);
        }
        let icons = Json::Object(icons);
        if self.environment_icons.as_ref() == Some(&icons) {
            return;
        }
        self.environment_icons = Some(icons.clone());
        self.bridge.publish(engine, ENVIRONMENT_ICONS, icons);
    }

    /// Asks the MC what this session may do, then runs `then`.
    fn with_session(&mut self, engine: &Engine, then: Then) {
        if self.may_operate.is_some() || !self.mc.is_ready() {
            then(self, engine);
            return;
        }
        let me = self.me.clone();
        self.mc.get(
            "/api/auth/session",
            Box::new(move |engine, result: Result<Json, McError>| {
                me.run(engine, move |c, engine| {
                    // A session that lists its scopes and lacks this one may
                    // only look; an MC that says nothing checks the write
                    // itself.
                    let may = match result.ok().as_ref().and_then(|s| s.get("scopes")) {
                        Some(Json::Array(scopes)) => {
                            scopes.iter().any(|s| s == "orchestration:operate")
                        }
                        _ => true,
                    };
                    c.may_operate = Some(may);
                    c.refresh_environments(engine);
                    then(c, engine);
                });
            }),
        );
    }

    fn set_environment_kind(&mut self, engine: &Engine, environment_id: &str, kind: &str) {
        if machine(kind).is_none() {
            return;
        }
        let lock = self.lock_of(engine, environment_id);
        if !lock.is_empty() {
            not_changed(engine, lock);
            return;
        }
        // With nothing detected the MC shows a server, so that kind clears
        // the choice too.
        let detected = match self.detected(environment_id) {
            d if machine(d).is_some() => d,
            _ => "server",
        };
        let value = (kind != detected).then(|| Json::from(kind));
        let target = environment_id.to_owned();
        let edit = Rc::new(move |settings: Json, id: &str| {
            if id == target {
                environment_settings::with(settings, "environmentIcon", value.clone())
            } else {
                settings
            }
        });
        let environment_id = environment_id.to_owned();
        let failed = move |engine: &Engine, outcome: Outcome| {
            if let Some(why) = outcome.failed.get(&environment_id) {
                not_changed(engine, why);
            }
        };
        if let Err(outcome) = self.settings.change(edit, failed.clone()) {
            failed(engine, outcome);
        }
    }
}

fn not_changed(engine: &Engine, why: &str) {
    controller::with::<Toasts, _>(engine, |toasts, engine| {
        toasts.error(engine, "Icon not changed", why);
    });
}
