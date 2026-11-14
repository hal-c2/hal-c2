//! `plugins`, desktop-qt's PluginController: this device's UI plugins, the
//! QML files in `<config dir>/plugins`, each a `Plugin` whose
//! `Contribution`s fill the bricks' `PluginSlot`s. The controller owns which
//! files there are, which are turned off and where a downloaded one came
//! from (`plugins.json` beside the directory, the TUI's format); the bricks'
//! PluginRegistry loads what `files` lists into the QML engine and reports
//! back what loaded and what did not.
//!
//! Publishes `plugins`: {dir, files: [{file, source, revision}], items: [{id,
//! file, order, description, slots, shown, url}], disabled: [{id, file}],
//! failed: [{id, file, message}]}. A file is read again whenever it changes
//! on disk (the directory is watched), so the registry replaces the plugin
//! in place; one that no longer loads leaves the version already running.
//!
//! Actions: `plugins.install {url}` downloads a plugin file after the user
//! has been told nothing vouches for it, `plugins.disable` / `.enable {id}`
//! turn one off and on (kept across restarts), `plugins.remove {id}` deletes
//! its file after a question, and `plugins.report {plugins, problems}` is the
//! registry's.
//!
//! The download runs on a thread of its own: [`set_wake`] says how that
//! thread reaches the Engine thread, which then calls [`deliver`]. The same
//! hand-over carries the directory watcher's news. A test gives its own
//! download with [`set_fetcher`].

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use ljos::prelude::Engine;
use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use serde_json::json;
use url::Url;

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::menus::Menus;
use crate::controllers::toasts::{DEFAULT_TIMEOUT_MS, Toasts};
use crate::json::Json;

const KEY: &str = "plugins";
const RECORDS: &str = "plugins.json";

/// What a downloaded plugin file may weigh.
pub const MAX_PLUGIN_BYTES: usize = 512 * 1024;
/// How long a download may take (QNetworkRequest::setTransferTimeout).
const TIMEOUT: Duration = Duration::from_secs(15);

/// What a download came to: the file's bytes, or why not. Runs on the
/// Engine thread.
pub type Download = Box<dyn FnOnce(&Engine, Result<Vec<u8>, String>)>;
/// Fetches an address and hands the answer to the [`Download`], never inside
/// the call.
pub type Fetcher = Rc<dyn Fn(&Engine, &str, Download)>;

type Wake = Arc<dyn Fn() + Send + Sync>;

/// What other threads leave for the Engine thread.
enum Event {
    /// The plugin directory changed.
    Changed,
    Downloaded(u64, Result<Vec<u8>, String>),
}

#[derive(Default)]
struct Shared {
    events: Mutex<Vec<Event>>,
    wake: Mutex<Option<Wake>>,
}

impl Shared {
    fn push(&self, event: Event) {
        self.events
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(event);
        let wake = self
            .wake
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        if let Some(wake) = wake {
            wake();
        }
    }
}

#[derive(Default)]
struct Hub {
    shared: Arc<Shared>,
    downloads: RefCell<HashMap<u64, Download>>,
    next: Cell<u64>,
    fetcher: RefCell<Option<Fetcher>>,
    config_dir: RefCell<Option<PathBuf>>,
}

impl Hub {
    fn of(engine: &Engine) -> Rc<Hub> {
        engine.extension::<Hub>()
    }
}

/// Says where the plugins are kept (`<dir>/plugins`); the launch does, before
/// the controllers start. None keeps none.
pub fn install(engine: &Engine, config_dir: Option<PathBuf>) {
    *Hub::of(engine).config_dir.borrow_mut() = config_dir;
}

/// Says what to run, on any thread, when [`deliver`] has something to do:
/// post a message to the Engine thread, which calls [`deliver`].
pub fn set_wake(engine: &Engine, wake: impl Fn() + Send + Sync + 'static) {
    let wake: Wake = Arc::new(wake);
    *Hub::of(engine)
        .shared
        .wake
        .lock()
        .unwrap_or_else(PoisonError::into_inner) = Some(wake);
}

/// Replaces the download (which fetches on a thread of its own); a test's
/// answers when it says.
pub fn set_fetcher(engine: &Engine, fetcher: Fetcher) {
    *Hub::of(engine).fetcher.borrow_mut() = Some(fetcher);
}

/// Hands the controller what the threads left: the finished downloads, and
/// that its directory changed. On the Engine thread.
pub fn deliver(engine: &Engine) {
    let hub = Hub::of(engine);
    let events = std::mem::take(
        &mut *hub
            .shared
            .events
            .lock()
            .unwrap_or_else(PoisonError::into_inner),
    );
    let mut changed = false;
    for event in events {
        match event {
            Event::Changed => changed = true,
            Event::Downloaded(id, result) => {
                let done = hub.downloads.borrow_mut().remove(&id);
                if let Some(done) = done {
                    done(engine, result);
                }
            }
        }
    }
    if changed {
        controller::with::<Plugin, _>(engine, |plugin, engine| plugin.scan(engine));
    }
}

fn fetch(engine: &Engine, url: &str, done: Download) {
    let hub = Hub::of(engine);
    let fetcher = hub.fetcher.borrow().clone();
    if let Some(fetcher) = fetcher {
        fetcher(engine, url, done);
        return;
    }
    let id = hub.next.get() + 1;
    hub.next.set(id);
    hub.downloads.borrow_mut().insert(id, done);
    let (shared, url) = (hub.shared.clone(), url.to_owned());
    let spawned = std::thread::Builder::new()
        .name("plugin-download".into())
        .spawn({
            let shared = shared.clone();
            move || {
                let result = hal_c2_mc::fetch(&url, TIMEOUT, MAX_PLUGIN_BYTES);
                shared.push(Event::Downloaded(id, result));
            }
        });
    if let Err(error) = spawned {
        shared.push(Event::Downloaded(id, Err(error.to_string())));
    }
}

/// A plugin turned off: its id, and the file it is.
#[derive(Clone, Debug, PartialEq)]
struct Disabled {
    id: String,
    file: String,
}

pub struct Plugin {
    bridge: Bridge,
    me: Me<Plugin>,
    config_dir: Option<PathBuf>,
    plugin_dir: Option<PathBuf>,
    disabled: Vec<Disabled>,
    /// File → the address it was downloaded from.
    sources: BTreeMap<String, String>,
    files: Vec<Json>,
    items: Vec<Json>,
    problems: Vec<Json>,
    /// Downloaded files the registry has not yet said anything about.
    checking: BTreeSet<String>,
    watcher: Option<RecommendedWatcher>,
}

impl Controller for Plugin {
    fn new(init: Init<'_, Self>) -> Self {
        let config_dir = Hub::of(init.engine).config_dir.borrow().clone();
        let mut plugin = Plugin {
            bridge: init.bridge,
            me: init.me,
            plugin_dir: config_dir.as_ref().map(|dir| dir.join("plugins")),
            config_dir,
            disabled: Vec::new(),
            sources: BTreeMap::new(),
            files: Vec::new(),
            items: Vec::new(),
            problems: Vec::new(),
            checking: BTreeSet::new(),
            watcher: None,
        };
        plugin.start(init.engine);
        plugin
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !action.starts_with("plugins.") {
            return false;
        }
        let id = payload.get("id").and_then(Json::as_str).unwrap_or_default();
        match action {
            "plugins.report" => self.report(engine, payload),
            "plugins.install" => {
                let address = payload
                    .get("url")
                    .and_then(Json::as_str)
                    .unwrap_or_default();
                self.install(engine, address.trim());
            }
            "plugins.disable" => self.disable(engine, id),
            "plugins.enable" => self.enable(engine, id),
            "plugins.remove" => self.remove(engine, id),
            _ => return false,
        }
        true
    }
}

/// The text of a plugin file's revision: its size, and a hash of it that
/// changes with the file.
fn revision(source: &[u8]) -> String {
    let hash = source.iter().fold(0xcbf2_9ce4_8422_2325_u64, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x0100_0000_01b3)
    });
    format!("{hash}:{}", source.len())
}

/// Whether `name` is a plugin file name: `[\w.-]+\.qml`.
fn is_plugin_file(name: &str) -> bool {
    name.len() > ".qml".len()
        && name.ends_with(".qml")
        && name
            .chars()
            .all(|c| c.is_alphanumeric() || matches!(c, '_' | '.' | '-'))
}

fn file_name(path: &str) -> &str {
    Path::new(path)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(path)
}

/// Writes `bytes` to `path` all at once or not at all (QSaveFile).
fn save(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let name = path
        .file_name()
        .map_or_else(String::new, |n| n.to_string_lossy().into_owned());
    let staging = path.with_file_name(format!(".{name}.saving"));
    std::fs::write(&staging, bytes)?;
    std::fs::rename(&staging, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&staging);
    })
}

impl Plugin {
    /// Makes the plugin directory, watches it, reads the records and the
    /// files; publishes even with nothing to load, as the list says what is
    /// turned off.
    fn start(&mut self, engine: &Engine) {
        if let Some(dir) = self.plugin_dir.clone() {
            let _ = std::fs::create_dir_all(&dir);
            let shared = Hub::of(engine).shared.clone();
            self.watcher =
                notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
                    if event.is_ok_and(|event| !event.kind.is_access()) {
                        shared.push(Event::Changed);
                    }
                })
                .ok();
            if let Some(watcher) = self.watcher.as_mut() {
                let _ = watcher.watch(&dir, RecursiveMode::NonRecursive);
            }
        }
        self.load_records();
        self.scan(engine);
        self.publish(engine);
    }

    /// The directory where plugin files are kept.
    pub fn plugin_dir(&self) -> Option<&Path> {
        self.plugin_dir.as_deref()
    }

    fn load_records(&mut self) {
        self.disabled.clear();
        self.sources.clear();
        let Some(dir) = &self.config_dir else { return };
        let Ok(text) = std::fs::read_to_string(dir.join(RECORDS)) else {
            return;
        };
        let records: Json = serde_json::from_str(&text).unwrap_or_default();
        let field = |entry: &Json, name: &str| {
            entry
                .get(name)
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        for entry in records["disabled"].as_array().into_iter().flatten() {
            let (id, file) = (field(entry, "id"), field(entry, "file"));
            if !id.is_empty() && !file.is_empty() {
                self.disabled.push(Disabled { id, file });
            }
        }
        for (file, url) in records["sources"].as_object().into_iter().flatten() {
            self.sources
                .insert(file.clone(), url.as_str().unwrap_or_default().to_owned());
        }
    }

    fn save_records(&self) {
        let Some(dir) = &self.config_dir else { return };
        let disabled: Vec<Json> = self
            .disabled
            .iter()
            .map(|d| json!({"id": d.id, "file": d.file}))
            .collect();
        let records = json!({"disabled": disabled, "sources": self.sources});
        if let Ok(text) = serde_json::to_string_pretty(&records) {
            let _ = save(&dir.join(RECORDS), text.as_bytes());
        }
    }

    /// The plugin files there are, less the ones turned off, each with its
    /// text: the registry instantiates that, so a save is seen as a new
    /// revision. Publishes when that list changed. Public for the tests that
    /// change the directory without waiting for the watcher.
    pub fn scan(&mut self, engine: &Engine) {
        let Some(dir) = &self.plugin_dir else { return };
        let mut paths: Vec<PathBuf> = std::fs::read_dir(dir)
            .into_iter()
            .flatten()
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| path.is_file() && path.extension().is_some_and(|e| e == "qml"))
            .collect();
        paths.sort();
        let watched: Vec<String> = paths
            .iter()
            .map(|path| path.to_string_lossy().into_owned())
            .collect();
        let mut files = Vec::new();
        for (path, name) in paths.iter().zip(&watched) {
            if self.disabled.iter().any(|d| &d.file == name) {
                continue;
            }
            let Ok(source) = std::fs::read(path) else {
                continue;
            };
            files.push(json!({
                "file": name,
                "source": String::from_utf8_lossy(&source),
                "revision": revision(&source),
            }));
        }
        // A turned-off plugin whose file is gone is gone.
        let before = self.disabled.len();
        self.disabled.retain(|d| watched.contains(&d.file));
        if self.disabled.len() != before {
            self.save_records();
        }
        if files == self.files {
            return;
        }
        self.files = files;
        self.publish(engine);
    }

    fn publish(&self, engine: &Engine) {
        let items: Vec<Json> = self
            .items
            .iter()
            .map(|item| {
                let mut item = item.as_object().cloned().unwrap_or_default();
                let url = item
                    .get("file")
                    .and_then(Json::as_str)
                    .and_then(|file| self.sources.get(file))
                    .cloned()
                    .unwrap_or_default();
                item.insert("url".into(), url.into());
                Json::Object(item)
            })
            .collect();
        let disabled: Vec<Json> = self
            .disabled
            .iter()
            .map(|d| json!({"id": d.id, "file": d.file}))
            .collect();
        let dir = self
            .plugin_dir
            .as_ref()
            .map_or_else(String::new, |d| d.to_string_lossy().into_owned());
        self.bridge.publish(
            engine,
            KEY,
            json!({
                "dir": dir,
                "files": self.files,
                "items": items,
                "disabled": disabled,
                "failed": self.problems,
            }),
        );
    }

    /// What the registry loaded ({id, file, order, description, slots}) and
    /// could not ({id, file, message}). The loader is the check of a
    /// downloaded file: one that is no plugin goes.
    fn report(&mut self, engine: &Engine, report: &Json) {
        let list = |name: &str| report[name].as_array().cloned().unwrap_or_default();
        self.items = list("plugins");
        self.problems = list("problems");
        let about = |list: &[Json], file: &str| {
            list.iter()
                .find(|entry| entry["file"].as_str() == Some(file))
                .cloned()
        };
        let mut removed = false;
        for file in std::mem::take(&mut self.checking) {
            if let Some(loaded) = about(&self.items, &file) {
                let id = loaded["id"].as_str().unwrap_or_default();
                self.toast(engine, "success", &format!("Plugin \"{id}\" loaded."), "");
                continue;
            }
            let Some(problem) = about(&self.problems, &file) else {
                // Not looked at yet.
                self.checking.insert(file);
                continue;
            };
            let message = problem["message"].as_str().unwrap_or_default().to_owned();
            self.toast(engine, "error", "The plugin could not be loaded", &message);
            removed = std::fs::remove_file(&file).is_ok() || removed;
            self.sources.remove(&file);
            self.save_records();
            self.problems
                .retain(|entry| entry["file"].as_str() != Some(file.as_str()));
        }
        self.publish(engine);
        if removed {
            self.scan(engine);
        }
    }

    fn install(&mut self, engine: &Engine, address: &str) {
        let url = Url::parse(address).ok().filter(|url| {
            matches!(url.scheme(), "http" | "https")
                && url
                    .path_segments()
                    .and_then(|mut s| s.next_back())
                    .is_some_and(is_plugin_file)
        });
        let Some(url) = url else {
            self.toast(
                engine,
                "error",
                "A plugin URL is an http(s) address of a .qml file.",
                "",
            );
            return;
        };
        let Some(dir) = &self.plugin_dir else { return };
        let name = url
            .path_segments()
            .and_then(|mut s| s.next_back())
            .unwrap_or_default()
            .to_owned();
        let file = dir.join(&name);
        let file = file.to_string_lossy().into_owned();
        if Path::new(&file).exists()
            && self.sources.get(&file).map(String::as_str) != Some(url.as_str())
        {
            self.toast(
                engine,
                "error",
                &format!("A plugin file named {name} is already installed."),
                "",
            );
            return;
        }
        // Nothing vouches for a pasted address: the user says so first.
        let me = self.me.clone();
        let accepted = {
            let (url, file, me) = (url.clone(), file, me.clone());
            Rc::new(move |engine: &Engine| {
                let (url, file, me) = (url.clone(), file.clone(), me.clone());
                let address = url.to_string();
                fetch(
                    engine,
                    &address,
                    Box::new(move |engine, result| {
                        me.run(engine, |c, engine| {
                            c.downloaded(engine, &url, &file, result)
                        });
                    }),
                );
            })
        };
        let declined = Rc::new(move |engine: &Engine| {
            me.run(engine, |c, engine| {
                c.toast(engine, "info", "Nothing was loaded.", "");
            });
        });
        let host = url.host_str().unwrap_or_default().to_owned();
        controller::with::<Menus, _>(engine, |menus, engine| {
            menus.confirm(
                engine,
                "Load this unsigned plugin?",
                &format!(
                    "This plugin is not signed: nothing vouches for what {host} serves, and a plugin runs with this app's own access."
                ),
                "Load plugin",
                true,
                Some(accepted),
                Some(declined),
            );
        });
    }

    /// The file arrived: it is kept and the registry is to look at it.
    fn downloaded(
        &mut self,
        engine: &Engine,
        url: &Url,
        file: &str,
        result: Result<Vec<u8>, String>,
    ) {
        let failed = "The plugin could not be downloaded";
        let source = match result {
            Ok(source) => source,
            Err(error) => {
                self.toast(engine, "error", failed, &error);
                return;
            }
        };
        let empty = source.iter().all(u8::is_ascii_whitespace);
        if empty || source.len() > MAX_PLUGIN_BYTES {
            let what = if empty { "empty" } else { "too large" };
            self.toast(
                engine,
                "error",
                failed,
                &format!("{} is {what}.", file_name(file)),
            );
            return;
        }
        if let Err(error) = save(Path::new(file), &source) {
            self.toast(engine, "error", failed, &error.to_string());
            return;
        }
        self.sources.insert(file.to_owned(), url.to_string());
        self.checking.insert(file.to_owned());
        self.save_records();
        self.scan(engine);
    }

    fn file_of(&self, id: &str) -> Option<String> {
        self.items
            .iter()
            .find(|item| item["id"].as_str() == Some(id))
            .and_then(|item| item["file"].as_str())
            .map(str::to_owned)
    }

    fn disable(&mut self, engine: &Engine, id: &str) {
        let Some(file) = self.file_of(id) else { return };
        self.disabled.retain(|d| d.id != id && d.file != file);
        self.disabled.push(Disabled {
            id: id.to_owned(),
            file,
        });
        self.save_records();
        self.scan(engine);
        self.publish(engine);
    }

    fn enable(&mut self, engine: &Engine, id: &str) {
        let before = self.disabled.len();
        self.disabled.retain(|d| d.id != id);
        if self.disabled.len() == before {
            return;
        }
        self.save_records();
        self.scan(engine);
        self.publish(engine);
    }

    fn remove(&mut self, engine: &Engine, id: &str) {
        let mut file = self.file_of(id);
        if let Some(entry) = self.disabled.iter().find(|d| d.id == id) {
            file = Some(entry.file.clone());
        }
        let Some(file) = file else { return };
        let me = self.me.clone();
        let removing = file.clone();
        let accepted = Rc::new(move |engine: &Engine| {
            let file = removing.clone();
            me.run(engine, |c, engine| {
                let _ = std::fs::remove_file(&file);
                c.sources.remove(&file);
                c.disabled.retain(|d| d.file != file);
                c.save_records();
                c.scan(engine);
                c.publish(engine);
            });
        });
        controller::with::<Menus, _>(engine, |menus, engine| {
            menus.confirm(
                engine,
                &format!("Remove the plugin \"{id}\"?"),
                &format!("This deletes {}.", file_name(&file)),
                "Remove plugin",
                true,
                Some(accepted),
                None,
            );
        });
    }

    /// A toast once no controller is running.
    fn toast(&self, engine: &Engine, kind: &'static str, title: &str, description: &str) {
        let (title, description) = (title.to_owned(), description.to_owned());
        self.bridge.defer(engine, move |engine| {
            controller::with::<Toasts, _>(engine, |toasts, engine| {
                toasts.show(engine, kind, &title, &description, None, DEFAULT_TIMEOUT_MS);
            });
        });
    }
}
