//! `mcPlugins`, desktop-qt's McPluginController: the plugins each
//! environment's MC runs (packages/contracts plugin.ts), and their UI parts.
//! Every online environment's `plugins` shape is followed; the files a
//! plugin's manifest names (pages, thread looks, slots, its settings page,
//! icon and screenshots) are fetched with `plugins.file` and kept under the
//! cache by environment, plugin and revision, so a new version is loaded from
//! its own files and an unchanged one is not fetched again.
//!
//! Publishes `mcPlugins`: {environments [{id, label, plugins [PluginEntry +
//! {environment, iconUrl, screenshotUrls [{url, caption}], settingsPageUrl}]}],
//! pages [{key ("<plugin>/<page>@<revision>"), pluginId, pageId, pluginName,
//! title, icon, url, error, environments [ids]}], one per page whatever runs
//! it, threadKinds {"<environment>/<plugin>/<kind>": {label, rowMark,
//! header}} of running plugins, slots [{slot, url, pluginId, environment,
//! order}]}. A page's `url` is empty while its file is on its way; `error`
//! says why it never will be.
//!
//! Actions: `mcPlugins.enable {environment, id}` (asks for the permissions
//! the plugin wants first, and enables it only with them), `.disable`,
//! `.restart`, `.rescan {environment}`; what the MC refuses is toasted.
//!
//! UI parts reach their MC part through the `McPlugins` singleton:
//! `call(environment, id, method, input)` answers with `answered(request,
//! result, error)`, and `watch(environment, id, topic)` follows a topic with
//! `published(watch, value)` until `unwatch(watch)` (PluginContext.qml wraps
//! both). `saveSettings(environment, id, settings)` is answered the same way,
//! so the page that saves them can show what the plugin refuses. The
//! singleton does not need the controller: it asks the MC itself.

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::rc::Rc;

use ljos::prelude::QmlValue;
use ljos::prelude::{Atom, Cx, Engine, QmlObject, Value, qml_impl, qml_singleton};
use serde_json::{Map, json};
use url::Url;

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::menus::Menus;
use crate::controllers::toasts::Toasts;
use crate::json::Json;
use crate::mc::{Mc, SubId};
use crate::store;

const KEY: &str = "mcPlugins";

/// What is told when something the controller keeps has changed.
type Listener = Rc<dyn Fn(&Engine)>;

#[derive(Default)]
struct Listeners {
    pages: RefCell<Vec<Listener>>,
    running: RefCell<Vec<Listener>>,
}

#[derive(Default)]
struct CacheDir(RefCell<Option<PathBuf>>);

/// Says where fetched files are kept (`<cache>/mc-plugins`); the launch does,
/// before the controllers start. Without one they go to the temporary
/// directory.
pub fn set_cache_dir(engine: &Engine, dir: PathBuf) {
    *engine.extension::<CacheDir>().0.borrow_mut() = Some(dir);
}

/// Runs `f` whenever the pages the window's tabs show have changed
/// (McPluginController::pagesChanged); once no controller is running.
pub fn on_pages_changed(engine: &Engine, f: impl Fn(&Engine) + 'static) {
    engine
        .extension::<Listeners>()
        .pages
        .borrow_mut()
        .push(Rc::new(f));
}

/// Runs `f` whenever what [`keeps_unlisted`] answers may have changed
/// (McPluginController::runningChanged).
pub fn on_running_changed(engine: &Engine, f: impl Fn(&Engine) + 'static) {
    engine
        .extension::<Listeners>()
        .running
        .borrow_mut()
        .push(Rc::new(f));
}

/// Whether the threads plugin `id` keeps out of the sidebar stay out: while
/// it runs on `environment`, or until that environment's plugins are known.
/// Once the plugin stops or goes, its threads are listed like any other.
/// True too when the controller is busy or absent, as before its plugins are
/// known.
pub fn keeps_unlisted(engine: &Engine, environment: &str, id: &str) -> bool {
    controller::with::<McPlugin, _>(engine, |c, _| c.keeps_unlisted(environment, id))
        .unwrap_or(true)
}

/// The published pages, for the window's tabs.
pub fn pages(engine: &Engine) -> Vec<Json> {
    controller::with::<McPlugin, _>(engine, |c, _| c.pages.clone()).unwrap_or_default()
}

fn notify(engine: &Engine, listeners: Vec<Listener>) {
    for listener in listeners {
        Bridge::of(engine).defer(engine, move |engine| listener(engine));
    }
}

fn text<'a>(value: &'a Json, field: &str) -> &'a str {
    value.get(field).and_then(Json::as_str).unwrap_or_default()
}

/// A name safe as one directory of the cache.
fn segment(name: &str) -> String {
    let safe: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') {
                c
            } else {
                '_'
            }
        })
        .collect();
    if safe.is_empty() || safe == "." || safe == ".." {
        "_".into()
    } else {
        safe
    }
}

fn running(entry: &Json) -> bool {
    text(entry, "status") == "running"
}

fn contributes(entry: &Json) -> &Json {
    &entry["contributes"]
}

/// The files a plugin's clients load: everything its manifest names while it
/// runs, and what the plugin list shows of it otherwise.
fn files_of(entry: &Json) -> Vec<String> {
    let parts = contributes(entry);
    let mut paths = vec![
        text(entry, "icon").to_owned(),
        text(parts, "settingsPage").to_owned(),
    ];
    for shot in entry["screenshots"].as_array().into_iter().flatten() {
        paths.push(text(shot, "path").to_owned());
    }
    if running(entry) {
        for page in parts["pages"].as_array().into_iter().flatten() {
            paths.push(text(page, "qml").to_owned());
        }
        for kind in parts["threadKinds"].as_array().into_iter().flatten() {
            paths.push(text(kind, "rowMark").to_owned());
            paths.push(text(kind, "header").to_owned());
        }
        for slot in parts["slots"].as_array().into_iter().flatten() {
            paths.push(text(slot, "qml").to_owned());
        }
    }
    let mut seen = HashSet::new();
    paths.retain(|path| !path.is_empty() && seen.insert(path.clone()));
    paths
}

fn file_url(path: &Path) -> String {
    Url::from_file_path(path).map_or_else(|()| path.to_string_lossy().into_owned(), String::from)
}

// -- The singleton the UI parts talk through ---------------------------------

/// A topic some UI parts follow, and the watches that share its
/// subscription.
#[derive(Default)]
struct Topic {
    subscription: Option<SubId>,
    watches: BTreeSet<i32>,
    last: Json,
    known: bool,
}

/// What `McPlugins` keeps: the requests and watches handed out, and the
/// topics. Not the controller's, so that a UI part is never refused because
/// the controller is running.
#[derive(Default)]
struct Channel {
    next_request: Cell<i32>,
    next_watch: Cell<i32>,
    topics: RefCell<HashMap<String, Topic>>,
    /// Watch → its topic.
    watches: RefCell<HashMap<i32, String>>,
}

impl Channel {
    fn of(engine: &Engine) -> Rc<Channel> {
        engine.extension::<Channel>()
    }

    /// Asks `method` of the MC serving `environment`; the answer comes as
    /// `answered`, after this returns.
    fn ask(&self, engine: &Engine, environment: &str, method: &str, input: Json) -> i32 {
        let request = self.next_request.get() + 1;
        self.next_request.set(request);
        match controller::mc(engine) {
            Some(mc) => mc.call(
                environment,
                method,
                input,
                Box::new(move |engine, result| match result {
                    Ok(result) => answered(engine, request, &result, ""),
                    Err(error) => answered(engine, request, &Json::Null, &error.message),
                }),
            ),
            None => {
                engine.call_at(engine.now(), move |engine| {
                    answered(engine, request, &Json::Null, "not connected");
                });
            }
        }
        request
    }

    fn watch(&self, engine: &Engine, environment: &str, id: &str, topic: &str) -> i32 {
        let Some(mc) = controller::mc(engine) else {
            return -1;
        };
        let key = format!("{environment}/{id}/{topic}");
        if !self.topics.borrow().contains_key(&key) {
            let shape = json!({
                "type": "plugin",
                "environment": environment,
                "id": id,
                "topic": topic,
            });
            let followed = key.clone();
            let subscription = mc.subscribe(
                shape,
                Box::new(move |engine, frame| {
                    if frame.get("t").and_then(Json::as_str) != Some("plugin") {
                        return;
                    }
                    let value = frame.get("value").cloned().unwrap_or(Json::Null);
                    Channel::of(engine).published(engine, &followed, value);
                }),
                None,
            );
            self.topics.borrow_mut().insert(
                key.clone(),
                Topic {
                    subscription: Some(subscription),
                    ..Topic::default()
                },
            );
        }
        let watch = self.next_watch.get() + 1;
        self.next_watch.set(watch);
        let known = {
            let mut topics = self.topics.borrow_mut();
            let followed = topics.entry(key.clone()).or_default();
            followed.watches.insert(watch);
            followed.known
        };
        self.watches.borrow_mut().insert(watch, key);
        if known {
            // After the caller has kept the watch, as when the MC answers.
            engine.call_at(engine.now(), move |engine| {
                let channel = Channel::of(engine);
                let value = channel.watches.borrow().get(&watch).and_then(|key| {
                    channel
                        .topics
                        .borrow()
                        .get(key)
                        .map(|t| (t.known, t.last.clone()))
                });
                if let Some((true, value)) = value {
                    publish_to(engine, watch, &value);
                }
            });
        }
        watch
    }

    /// What the topic `key` now says, to each of its watches.
    fn published(&self, engine: &Engine, key: &str, value: Json) {
        let watches: Vec<i32> = {
            let mut topics = self.topics.borrow_mut();
            let Some(followed) = topics.get_mut(key) else {
                return;
            };
            followed.last = value.clone();
            followed.known = true;
            followed.watches.iter().copied().collect()
        };
        for watch in watches {
            publish_to(engine, watch, &value);
        }
    }

    fn unwatch(&self, engine: &Engine, watch: i32) {
        let Some(key) = self.watches.borrow_mut().remove(&watch) else {
            return;
        };
        let subscription = {
            let mut topics = self.topics.borrow_mut();
            let Some(followed) = topics.get_mut(&key) else {
                return;
            };
            followed.watches.remove(&watch);
            if !followed.watches.is_empty() {
                return;
            }
            topics.remove(&key).and_then(|t| t.subscription)
        };
        if let (Some(id), Some(mc)) = (subscription, controller::mc(engine)) {
            mc.unsubscribe(id);
        }
    }
}

fn answered(engine: &Engine, request: i32, result: &Json, error: &str) {
    let Ok(object) = engine.singleton::<McPluginsObject>() else {
        return;
    };
    let result = if error.is_empty() {
        result.to_value()
    } else {
        Value::Undefined
    };
    let _ = McPluginsObject::emit_answered(
        &Cx::new(engine, object),
        request,
        result,
        Atom::from(error),
    );
}

fn publish_to(engine: &Engine, watch: i32, value: &Json) {
    let Ok(object) = engine.singleton::<McPluginsObject>() else {
        return;
    };
    let _ = McPluginsObject::emit_published(&Cx::new(engine, object), watch, value.to_value());
}

/// How a UI part reaches its plugin's MC part.
///
/// ```qml
/// const request = McPlugins.call(environment, "reviews", "list", {})
/// // onAnswered(request, result, error): error is "" when it worked
/// const watch = McPlugins.watch(environment, "reviews", "open")
/// // onPublished(watch, value); McPlugins.unwatch(watch) ends it
/// ```
#[derive(Debug, Default, QmlObject)]
// Not `uncreatable`: Ljós then cannot make the singleton either.
#[qml(module = "HalC2.Shell", name = "McPlugins")]
#[qml_singleton]
pub struct McPluginsObject {}

#[qml_impl]
impl McPluginsObject {
    #[qml(signal)]
    fn answered(request: i32, result: Value, error: Atom);
    #[qml(signal)]
    fn published(watch: i32, value: Value);

    /// Asks plugin `id` on `environment` (`plugins.call`).
    #[qml(invokable)]
    fn call(cx: &Cx, environment: Atom, id: Atom, method: Atom, input: Json) -> i32 {
        Channel::of(cx.engine).ask(
            cx.engine,
            &environment,
            "plugins.call",
            json!({"id": &*id, "method": &*method, "input": input}),
        )
    }

    /// Saves plugin `id`'s settings on `environment` (`plugins.saveSettings`).
    #[qml(invokable)]
    fn save_settings(cx: &Cx, environment: Atom, id: Atom, settings: Json) -> i32 {
        let settings = if settings.is_object() {
            settings
        } else {
            json!({})
        };
        Channel::of(cx.engine).ask(
            cx.engine,
            &environment,
            "plugins.saveSettings",
            json!({"id": &*id, "settings": settings}),
        )
    }

    /// Follows what plugin `id` publishes on `topic`. Watches of one topic
    /// share one subscription, and a later one is given the last value at
    /// once, so a part repeated per row costs one topic's traffic.
    #[qml(invokable)]
    fn watch(cx: &Cx, environment: Atom, id: Atom, topic: Atom) -> i32 {
        Channel::of(cx.engine).watch(cx.engine, &environment, &id, &topic)
    }

    #[qml(invokable)]
    fn unwatch(cx: &Cx, watch: i32) {
        Channel::of(cx.engine).unwatch(cx.engine, watch);
    }
}

// -- The controller ----------------------------------------------------------

/// One plugin's files at one revision.
#[derive(Default)]
struct Files {
    revision: String,
    runs: bool,
    /// Path → local file URL.
    urls: HashMap<String, String>,
    /// Path → why it could not be fetched.
    errors: HashMap<String, String>,
    pending: HashSet<String>,
}

pub struct McPlugin {
    bridge: Bridge,
    me: Me<McPlugin>,
    mc: Rc<dyn Mc>,
    active: bool,
    cache_dir: PathBuf,
    /// Environment → its `plugins` shape.
    subscriptions: BTreeMap<String, SubId>,
    /// Environment → PluginEntry[].
    plugins: HashMap<String, Vec<Json>>,
    /// Environment → ids of the plugins running on it.
    running: HashMap<String, HashSet<String>>,
    /// "<environment>/<id>" → files.
    files: HashMap<String, Files>,
    pages: Vec<Json>,
    /// Page key → the url its tab shows.
    page_urls: HashMap<String, String>,
}

impl Controller for McPlugin {
    fn new(init: Init<'_, Self>) -> Self {
        let cache_dir = init
            .engine
            .extension::<CacheDir>()
            .0
            .borrow()
            .clone()
            .unwrap_or_else(|| std::env::temp_dir().join("hal-c2-mc-plugins"));
        McPlugin {
            bridge: init.bridge,
            me: init.me,
            mc: init.mc,
            active: false,
            cache_dir,
            subscriptions: BTreeMap::new(),
            plugins: HashMap::new(),
            running: HashMap::new(),
            files: HashMap::new(),
            pages: Vec::new(),
            page_urls: HashMap::new(),
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if std::mem::replace(&mut self.active, true) {
            return;
        }
        store::on_changed(engine, |engine| {
            controller::with::<McPlugin, _>(engine, |c, engine| c.follow(engine));
        });
        self.follow(engine);
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !action.starts_with("mcPlugins.") {
            return false;
        }
        let environment = text(payload, "environment");
        let id = text(payload, "id");
        if action == "mcPlugins.rescan" {
            if !environment.is_empty() {
                self.request(
                    environment,
                    "plugins.rescan",
                    json!({}),
                    "The MC could not look for plugins",
                );
            }
            return true;
        }
        if environment.is_empty() || id.is_empty() {
            return true;
        }
        let input = json!({"id": id});
        match action {
            "mcPlugins.enable" => self.enable(engine, environment, id),
            "mcPlugins.disable" => self.request(
                environment,
                "plugins.disable",
                input,
                "The plugin could not be disabled",
            ),
            "mcPlugins.restart" => self.request(
                environment,
                "plugins.restart",
                input,
                "The plugin could not be restarted",
            ),
            _ => return false,
        }
        true
    }
}

impl McPlugin {
    fn label(&self, engine: &Engine, environment: &str) -> String {
        let label = store::with(engine, |s| {
            text(&Json::Object(s.environment(environment)), "label").to_owned()
        });
        if label.is_empty() {
            environment.to_owned()
        } else {
            label
        }
    }

    /// Every online environment's plugins; an environment that goes offline
    /// takes its plugins with it until it is back.
    fn follow(&mut self, engine: &Engine) {
        if !self.active {
            return;
        }
        let online: Vec<String> = store::with(engine, |s| {
            s.environments()
                .into_iter()
                .filter(|environment| s.environment_online(environment))
                .collect()
        });
        let mut dropped = false;
        let gone: Vec<String> = self
            .subscriptions
            .keys()
            .filter(|environment| !online.contains(environment))
            .cloned()
            .collect();
        for environment in gone {
            if let Some(id) = self.subscriptions.remove(&environment) {
                self.mc.unsubscribe(id);
            }
            self.plugins.remove(&environment);
            // What could not be fetched from it is asked for again once it
            // is back.
            let prefix = format!("{environment}/");
            self.files.retain(|key, _| !key.starts_with(&prefix));
            dropped = true;
        }
        for environment in online {
            if self.subscriptions.contains_key(&environment) {
                continue;
            }
            let shape = json!({"type": "plugins", "environment": environment});
            let (me, followed) = (self.me.clone(), environment.clone());
            let id = self.mc.subscribe(
                shape,
                Box::new(move |engine, frame| {
                    if frame.get("t").and_then(Json::as_str) != Some("plugins") {
                        return;
                    }
                    let plugins = frame
                        .get("plugins")
                        .and_then(Json::as_array)
                        .cloned()
                        .unwrap_or_default();
                    me.run(engine, |c, engine| {
                        for entry in &plugins {
                            c.fetch(&followed, entry);
                        }
                        c.plugins.insert(followed.clone(), plugins.clone());
                        c.publish(engine);
                        c.note_running(engine);
                    });
                }),
                None,
            );
            self.subscriptions.insert(environment, id);
        }
        if dropped {
            self.publish(engine);
            self.note_running(engine);
        }
    }

    pub fn keeps_unlisted(&self, environment: &str, id: &str) -> bool {
        self.running
            .get(environment)
            .is_none_or(|ids| ids.contains(id))
    }

    fn note_running(&mut self, engine: &Engine) {
        let now: HashMap<String, HashSet<String>> = self
            .plugins
            .iter()
            .map(|(environment, entries)| {
                let ids = entries
                    .iter()
                    .filter(|entry| running(entry))
                    .map(|entry| text(entry, "id").to_owned())
                    .collect();
                (environment.clone(), ids)
            })
            .collect();
        if now == self.running {
            return;
        }
        self.running = now;
        let listeners = engine.extension::<Listeners>().running.borrow().clone();
        notify(engine, listeners);
    }

    /// Where `path` of a plugin's files is kept. What a running plugin's
    /// clients load is kept apart from what the plugin list shows of it
    /// otherwise, so a directory QML has read never gains a file: Qt lists a
    /// directory once and then refuses files that were not in it.
    fn cache_path(
        &self,
        environment: &str,
        id: &str,
        revision: &str,
        runs: bool,
        path: &str,
    ) -> PathBuf {
        let mut file = self.cache_dir.join(segment(environment));
        file.push(segment(id));
        file.push(segment(revision));
        file.push(if runs { "running" } else { "listed" });
        for part in path.split('/').filter(|part| !part.is_empty()) {
            file.push(segment(part));
        }
        file
    }

    /// Fetches what the plugin's clients load at its current revision; a file
    /// already kept for that revision is not asked for again. None of them is
    /// shown until all have come, for the reason `cache_path` gives.
    fn fetch(&mut self, environment: &str, entry: &Json) {
        let id = text(entry, "id").to_owned();
        let revision = text(entry, "revision").to_owned();
        let runs = running(entry);
        if id.is_empty() || revision.is_empty() {
            return;
        }
        let key = format!("{environment}/{id}");
        let stale = self
            .files
            .get(&key)
            .is_none_or(|files| files.revision != revision || files.runs != runs);
        // What failed stays failed until the plugin starts, stops or changes
        // version, so the list's other news does not take a failed page back
        // to loading.
        if stale {
            self.files.insert(
                key.clone(),
                Files {
                    revision: revision.clone(),
                    runs,
                    ..Files::default()
                },
            );
            // Only what the plugin is at now is kept, or every version it
            // went through would stay on the device. Nothing shows the other
            // versions' files any more.
            let kept = self.cache_path(environment, &id, &revision, runs, "");
            if let Some(version) = kept.parent() {
                for dir in [version.parent(), Some(version)].into_iter().flatten() {
                    for other in std::fs::read_dir(dir).into_iter().flatten().flatten() {
                        let path = other.path();
                        if path.is_dir() && path != version && path != kept {
                            let _ = std::fs::remove_dir_all(&path);
                        }
                    }
                }
            }
        }
        for path in files_of(entry) {
            let files = self.files.get_mut(&key).expect("just made");
            if files.urls.contains_key(&path)
                || files.errors.contains_key(&path)
                || files.pending.contains(&path)
            {
                continue;
            }
            let local = self.cache_path(environment, &id, &revision, runs, &path);
            let files = self.files.get_mut(&key).expect("just made");
            if local.exists() {
                files.urls.insert(path, file_url(&local));
                continue;
            }
            files.pending.insert(path.clone());
            let me = self.me.clone();
            let (environment, id, key, revision) = (
                environment.to_owned(),
                id.clone(),
                key.clone(),
                revision.clone(),
            );
            let asked = json!({"id": id, "path": path});
            self.mc.call(
                &environment.clone(),
                "plugins.file",
                asked,
                Box::new(move |engine, result| {
                    me.run(engine, |c, engine| {
                        c.fetched(
                            engine,
                            (&environment, &id, &key, &revision, runs, &path),
                            result,
                        );
                    });
                }),
            );
        }
    }

    /// `plugins.file` answered for `path` of the plugin at `revision`.
    fn fetched(
        &mut self,
        engine: &Engine,
        (environment, id, key, revision, runs, path): (&str, &str, &str, &str, bool, &str),
        result: Result<Json, crate::mc::McError>,
    ) {
        let local = self.cache_path(environment, id, revision, runs, path);
        let Some(files) = self.files.get_mut(key) else {
            return;
        };
        if files.revision != revision || files.runs != runs {
            return;
        }
        files.pending.remove(path);
        match result {
            Err(error) => {
                files.errors.insert(path.to_owned(), error.message);
            }
            // A newer version answered: its own list brings it.
            Ok(file) if text(&file, "revision") != revision => return,
            Ok(file) => {
                let content = text(&file, "content");
                let bytes = if text(&file, "encoding") == "base64" {
                    base64::Engine::decode(&base64::engine::general_purpose::STANDARD, content)
                        .unwrap_or_default()
                } else {
                    content.as_bytes().to_vec()
                };
                let kept = local
                    .parent()
                    .map_or(Ok(()), std::fs::create_dir_all)
                    .and_then(|()| std::fs::write(&local, &bytes));
                match kept {
                    Ok(()) => {
                        files.urls.insert(path.to_owned(), file_url(&local));
                    }
                    Err(error) => {
                        files.errors.insert(
                            path.to_owned(),
                            format!("{path} could not be kept: {error}"),
                        );
                    }
                }
            }
        }
        self.publish(engine);
    }

    fn publish(&mut self, engine: &Engine) {
        if !self.active {
            return;
        }
        let mut environments = Vec::new();
        let mut pages: Vec<Json> = Vec::new();
        let mut page_at: HashMap<String, usize> = HashMap::new();
        // Page key → the urls of its environments' copies that are ready.
        let mut offered: HashMap<String, Vec<String>> = HashMap::new();
        let mut tabs: HashMap<String, usize> = HashMap::new();
        let mut thread_kinds = Map::new();
        let mut slot_parts = Vec::new();
        let ids = store::with(engine, |s| s.environments());
        for environment in ids {
            let Some(entries) = self.plugins.get(&environment) else {
                continue;
            };
            let mut shown_plugins = Vec::new();
            for entry in entries {
                let id = text(entry, "id");
                let empty = Files::default();
                let files = self
                    .files
                    .get(&format!("{environment}/{id}"))
                    .unwrap_or(&empty);
                let current = files.revision == text(entry, "revision")
                    && files.runs == running(entry)
                    && files.pending.is_empty();
                let url = |path: &str| -> String {
                    if current {
                        files.urls.get(path).cloned().unwrap_or_default()
                    } else {
                        String::new()
                    }
                };
                let failed = |path: &str| -> String {
                    if current {
                        files.errors.get(path).cloned().unwrap_or_default()
                    } else {
                        String::new()
                    }
                };

                let mut shown = entry.as_object().cloned().unwrap_or_default();
                shown.insert("environment".into(), environment.clone().into());
                shown.insert("iconUrl".into(), url(text(entry, "icon")).into());
                let shots: Vec<Json> = entry["screenshots"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|shot| json!({"url": url(text(shot, "path")), "caption": text(shot, "caption")}))
                    .collect();
                shown.insert("screenshotUrls".into(), shots.into());
                shown.insert(
                    "settingsPageUrl".into(),
                    url(text(contributes(entry), "settingsPage")).into(),
                );
                shown_plugins.push(Json::Object(shown));
                if !running(entry) {
                    continue;
                }

                let parts = contributes(entry);
                for page in parts["pages"].as_array().into_iter().flatten() {
                    let page_id = text(page, "id");
                    let path = text(page, "qml");
                    let page_key = format!("{id}/{page_id}");
                    // One tab per page, whichever environments run the
                    // plugin, as long as they run the same version of it: one
                    // page's code cannot be given another version's MC part to
                    // talk to, so an environment on another revision gets a
                    // tab of its own. The key names the version, so
                    // environments coming and going leave it alone.
                    let group = format!("{page_key}@{}", text(entry, "revision"));
                    if let Some(&at) = page_at.get(&group) {
                        if !url(path).is_empty() {
                            offered.entry(group.clone()).or_default().push(url(path));
                        }
                        let merged = &mut pages[at];
                        if let Some(list) = merged["environments"].as_array_mut() {
                            list.push(environment.clone().into());
                        }
                        if text(merged, "url").is_empty() && !url(path).is_empty() {
                            merged["url"] = url(path).into();
                            merged["error"] = "".into();
                        }
                        continue;
                    }
                    page_at.insert(group.clone(), pages.len());
                    if !url(path).is_empty() {
                        offered.entry(group.clone()).or_default().push(url(path));
                    }
                    pages.push(json!({
                        "key": group,
                        "pluginId": id,
                        "pageId": page_id,
                        "pluginName": text(entry, "name"),
                        "title": text(page, "title"),
                        "icon": text(page, "icon"),
                        "url": url(path),
                        "error": failed(path),
                        "environments": [environment],
                    }));
                    *tabs.entry(page_key).or_default() += 1;
                }
                for kind in parts["threadKinds"].as_array().into_iter().flatten() {
                    thread_kinds.insert(
                        format!("{environment}/{id}/{}", text(kind, "kind")),
                        json!({
                            "label": text(kind, "label"),
                            "rowMark": url(text(kind, "rowMark")),
                            "header": url(text(kind, "header")),
                        }),
                    );
                }
                for slot in parts["slots"].as_array().into_iter().flatten() {
                    let slot_url = url(text(slot, "qml"));
                    if slot_url.is_empty() {
                        continue;
                    }
                    slot_parts.push(json!({
                        "slot": text(slot, "slot"),
                        "url": slot_url,
                        "pluginId": id,
                        "environment": environment,
                        "order": slot["order"].as_i64().unwrap_or(0),
                    }));
                }
            }
            environments.push(json!({
                "id": environment,
                "label": self.label(engine, &environment),
                "plugins": shown_plugins,
            }));
        }
        // A page keeps the copy it shows while that copy is still ready: the
        // copies of one revision are interchangeable, and a page made anew
        // from another copy's url would lose whatever it held. Only the first
        // copy to be ready, or a new revision, sets it.
        let mut shown_urls = HashMap::new();
        for page in &mut pages {
            let key = text(page, "key").to_owned();
            if let Some(kept) = self.page_urls.get(&key)
                && offered.get(&key).is_some_and(|urls| urls.contains(kept))
            {
                page["url"] = kept.clone().into();
                page["error"] = "".into();
            }
            if !text(page, "url").is_empty() {
                shown_urls.insert(key, text(page, "url").to_owned());
            }
        }
        self.page_urls = shown_urls;
        // A page split by version says which environments each of its tabs
        // is for.
        for page in &mut pages {
            let page_key = format!("{}/{}", text(page, "pluginId"), text(page, "pageId"));
            if tabs.get(&page_key).copied().unwrap_or(0) < 2 {
                continue;
            }
            let labels: Vec<String> = page["environments"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Json::as_str)
                .map(|environment| self.label(engine, environment))
                .collect();
            page["title"] = format!("{} · {}", text(page, "title"), labels.join(", ")).into();
        }
        self.bridge.publish(
            engine,
            KEY,
            json!({
                "environments": environments,
                "pages": pages,
                "threadKinds": thread_kinds,
                "slots": slot_parts,
            }),
        );
        if pages != self.pages {
            self.pages = pages;
            let listeners = engine.extension::<Listeners>().pages.borrow().clone();
            notify(engine, listeners);
        }
    }

    /// A plugin runs only with the permissions it asks for, so the user sees
    /// each one, and why, before it starts.
    fn enable(&mut self, engine: &Engine, environment: &str, id: &str) {
        let entry = self
            .plugins
            .get(environment)
            .and_then(|entries| entries.iter().find(|e| text(e, "id") == id))
            .cloned()
            .unwrap_or(Json::Null);
        let mut accepted = Vec::new();
        let mut lines = Vec::new();
        for permission in entry["permissions"].as_array().into_iter().flatten() {
            accepted.push(text(permission, "id").to_owned());
            let reason = text(permission, "reason");
            let label = text(permission, "label");
            lines.push(if reason.is_empty() {
                format!("• {label}")
            } else {
                format!("• {label}: {reason}")
            });
        }
        if entry["runsCode"].as_bool().unwrap_or(false) {
            lines.push(format!(
                "It runs its own code inside the MC on {}.",
                self.label(engine, environment)
            ));
        }
        let input = json!({"id": id, "acceptPermissions": accepted});
        let failed = "The plugin could not be enabled";
        if lines.is_empty() {
            self.request(environment, "plugins.enable", input, failed);
            return;
        }
        let name = text(&entry, "name");
        let title = format!("Enable \"{}\"?", if name.is_empty() { id } else { name });
        let me = self.me.clone();
        let environment = environment.to_owned();
        let accepted = Rc::new(move |engine: &Engine| {
            let (environment, input) = (environment.clone(), input.clone());
            me.run(engine, |c, _| {
                c.request(&environment, "plugins.enable", input, failed);
            });
        });
        controller::with::<Menus, _>(engine, |menus, engine| {
            menus.confirm(
                engine,
                &title,
                &format!("It asks to:\n{}", lines.join("\n")),
                "Enable",
                false,
                Some(accepted),
                None,
            );
        });
    }

    /// Calls `method`; what the MC refuses is toasted as `failed`.
    fn request(&self, environment: &str, method: &str, input: Json, failed: &'static str) {
        let bridge = self.bridge;
        self.mc.call(
            environment,
            method,
            input,
            Box::new(move |engine, result| {
                let Err(error) = result else { return };
                bridge.defer(engine, move |engine| {
                    controller::with::<Toasts, _>(engine, |toasts, engine| {
                        toasts.error(engine, failed, &error.message);
                    });
                });
            }),
        );
    }
}
