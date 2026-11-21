//! `--audit --load`: an MC that keeps the shell busy the way a working day
//! does, so the audit judges the shell loaded rather than empty. It serves
//! one environment of [`PROJECTS`] projects and [`THREADS`] threads (some
//! pinned, some running, one waiting on a question) and the code-review
//! plugin, read from the checkout's `plugins/code-review`; then, every
//! [`TICK`] of the engine's clock, a `shell.rows` frame that moves a few
//! threads along and a publish of the plugin's `threads` topic, a value of
//! one entry a thread, with the flat fields its MC part publishes (`key`,
//! `repository`, `number`, `title`, `url`, the branches, `status`,
//! `verdict`, `version`: `threads/1` in `plugins/code-review/mc`).
//!
//! Everything it sends is made from the tick's number, and it runs on the
//! engine's clock, so the load is the same on every run and on every
//! machine; it ends when the audit stops letting time pass.

use std::cell::{Cell, RefCell};
use std::path::{Component, Path, PathBuf};
use std::rc::Rc;
use std::time::Duration;

use hal_c2_shell::json::Json;
use hal_c2_shell::mc::{Mc, McError, OnFrame, OnReady, Reply, Resume, SubId};
use hal_c2_shell::schedule;
use ljos::prelude::Engine;
use serde_json::json;

/// The origin the shell is given for it; nothing is opened there.
pub const ORIGIN: &str = "http://audit.invalid";
const MC: &str = "mc-audit";
const ENVIRONMENT: &str = "env-audit";
const PLUGIN: &str = "code-review";
const PROJECTS: usize = 6;
const THREADS: usize = 90;
/// Threads every tick moves along.
const MOVED: usize = 6;
/// How often the MC has news.
const TICK: Duration = Duration::from_millis(250);

fn at(seconds: usize) -> String {
    let (m, s) = (seconds / 60 % 60, seconds % 60);
    format!("2026-11-20T{:02}:{m:02}:{s:02}.000Z", 9 + seconds / 3600)
}

fn project(p: usize) -> Json {
    json!({
        "id": format!("p{p}"),
        "title": format!("Project {p}"),
        "workspaceRoot": format!("/work/project-{p}"),
        "createdAt": at(0),
        "updatedAt": at(0),
    })
}

/// Thread `t` as it is at `tick`.
fn thread(t: usize, tick: usize) -> Json {
    let running = (t + tick).is_multiple_of(9);
    let mut row = json!({
        "id": format!("t{t}"),
        "projectId": format!("p{}", t % PROJECTS),
        "title": format!("Thread {t}: {}", ["fix the sidebar", "review the pull request",
            "port the page", "find the leak", "write the tests"][t % 5]),
        "branch": format!("feature/work-{t}"),
        "createdAt": at(t),
        "updatedAt": at(t + tick * 7),
        "latestUserMessageAt": at(t + tick * 7),
        "runtimeMode": "full-access",
        "interactionMode": "default",
        "latestRunId": format!("run-{t}-{}", tick / 4),
        "status": if running { "running" } else { "idle" },
    });
    if running {
        row["activeRunId"] = json!(format!("run-{t}-{}", tick / 4));
    }
    if t.is_multiple_of(15) {
        row["pinnedAt"] = json!(at(t));
    }
    if t == 7 {
        row["pendingRuntimeRequest"] = json!({"kind": "user_input", "requestId": "q-7"});
    }
    if t.is_multiple_of(4) {
        row["plugin"] = json!({"id": PLUGIN, "kind": "review", "listed": true});
    }
    row
}

/// The code-review plugin's `threads` topic at `tick`: a review a review
/// thread, as the plugin's MC part publishes it (`threads/1` takes
/// `@thread_fields` and adds `version`): flat `number` and `url`, which
/// `ReviewHeader.qml` reads as `review.number` and `review.url`, and no
/// findings (those are on the `reviews` topic).
fn reviews(tick: usize) -> Json {
    let mut out = serde_json::Map::new();
    for t in (0..THREADS).filter(|t| t.is_multiple_of(4)) {
        let status = ["queued", "running", "waiting", "published"][(t + tick) % 4];
        let number = 1000 + t;
        out.insert(
            format!("t{t}"),
            json!({
                "key": format!("audit-org/audit-repo#{number}"),
                "repository": "audit-org/audit-repo",
                "number": number,
                "title": format!("Pull request {number}"),
                "url": format!("https://example.invalid/pr/{number}"),
                "headBranch": format!("feature/work-{t}"),
                "baseBranch": "main",
                "status": status,
                "verdict": if (t + tick).is_multiple_of(3) { "approve" } else { "comment" },
                "version": format!("audit-{t}-{tick}"),
                "sandboxed": false,
            }),
        );
    }
    Json::Object(out)
}

/// Whether `plugins.file` may serve `path`: only a path of plain names, so
/// it stays under the plugin's directory (an absolute path would replace
/// it in `Path::join`, and `..` would walk out of it).
fn servable(path: &str) -> bool {
    let mut parts = Path::new(path).components().peekable();
    parts.peek().is_some() && parts.all(|part| matches!(part, Component::Normal(_)))
}

/// Reads and parses the plugin's manifest in `dir`; the raw text is kept
/// for [`revision_for`].
fn load_manifest(dir: &Path) -> Result<(String, Json), String> {
    let file = dir.join("plugin.json");
    let text = std::fs::read_to_string(&file)
        .map_err(|e| format!("the audit's plugin manifest {}: {e}", file.display()))?;
    let manifest = serde_json::from_str(&text)
        .map_err(|e| format!("the audit's plugin manifest {}: {e}", file.display()))?;
    Ok((text, manifest))
}

/// The plugin files the shell asks for, from its manifest: what
/// `mc_plugin::fetch` requests for a running plugin.
fn served_paths(manifest: &Json) -> Vec<String> {
    let contributes = &manifest["contributes"];
    let mut paths: Vec<String> = [
        manifest["icon"].as_str(),
        contributes["settingsPage"].as_str(),
    ]
    .into_iter()
    .flatten()
    .map(str::to_owned)
    .collect();
    for page in contributes["pages"].as_array().into_iter().flatten() {
        if let Some(qml) = page["qml"].as_str() {
            paths.push(qml.to_owned());
        }
    }
    for kind in contributes["threadKinds"].as_array().into_iter().flatten() {
        for field in ["rowMark", "header"] {
            if let Some(qml) = kind[field].as_str() {
                paths.push(qml.to_owned());
            }
        }
    }
    for slot in contributes["slots"].as_array().into_iter().flatten() {
        if let Some(qml) = slot["qml"].as_str() {
            paths.push(qml.to_owned());
        }
    }
    paths.sort();
    paths.dedup();
    paths
}

/// The revision the plugin is served at: made of the manifest and the
/// served files' contents, so an edit between runs is a new revision and
/// `McPlugin::fetch` does not reuse the files a run with the same home
/// kept for the old one.
fn revision_for(manifest: &str, files: &[(String, Vec<u8>)]) -> String {
    use sha2::Digest as _;
    let mut hash = sha2::Sha256::new();
    hash.update(manifest.as_bytes());
    for (path, bytes) in files {
        hash.update(path.as_bytes());
        hash.update([0]);
        hash.update(bytes);
        hash.update([0]);
    }
    let digest = hash.finalize();
    let hex: String = digest.iter().take(8).map(|b| format!("{b:02x}")).collect();
    format!("audit-{hex}")
}

struct Subscription {
    id: SubId,
    shape: Json,
    on_frame: Rc<RefCell<OnFrame>>,
}

/// Work the loaded clock runs after each tick's frames ([`Loaded::on_tick`]).
type TickWork = dyn Fn(&Engine);

/// The loaded MC; [`Loaded::start`] after the shell starts.
pub struct Loaded {
    plugin_dir: PathBuf,
    /// The plugin's manifest, read at setup: a load audit that cannot
    /// serve its plugin has nothing to audit.
    manifest: Json,
    /// The revision the plugin is served at, in the `plugins` frame and
    /// every `plugins.file` reply: [`revision_for`] of what is served.
    revision: String,
    next: Cell<u64>,
    tick: Cell<usize>,
    subscriptions: RefCell<Vec<Subscription>>,
    /// Subscriptions that have not had their first frame.
    fresh: RefCell<Vec<SubId>>,
    replies: RefCell<Vec<(Reply, Result<Json, McError>)>>,
    /// Run on every tick after the tick's frames, for work the picture
    /// has no frame loop for (the caller drains the shell's cache).
    after_tick: RefCell<Option<Rc<TickWork>>>,
}

impl Loaded {
    pub fn new() -> Result<Rc<Loaded>, String> {
        let plugin_dir =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../plugins/code-review");
        let (text, manifest) = load_manifest(&plugin_dir)?;
        let mut files = Vec::new();
        for path in served_paths(&manifest) {
            if !servable(&path) {
                return Err(format!(
                    "the audit's plugin manifest names {path}, which it may not serve"
                ));
            }
            let bytes = std::fs::read(plugin_dir.join(&path)).map_err(|e| {
                format!(
                    "the audit's plugin file {}: {e}",
                    plugin_dir.join(&path).display()
                )
            })?;
            files.push((path, bytes));
        }
        let revision = revision_for(&text, &files);
        Ok(Rc::new(Loaded {
            plugin_dir,
            manifest,
            revision,
            next: Cell::new(0),
            tick: Cell::new(0),
            subscriptions: RefCell::default(),
            fresh: RefCell::default(),
            replies: RefCell::default(),
            after_tick: RefCell::default(),
        }))
    }

    /// Runs `f` on every tick, after the tick's frames have been
    /// delivered and before what it set off is.
    pub fn on_tick(&self, f: impl Fn(&Engine) + 'static) {
        *self.after_tick.borrow_mut() = Some(Rc::new(f));
    }

    /// Answers what was asked and sends what was subscribed, until nothing
    /// more is; then has news every [`TICK`].
    pub fn start(self: &Rc<Self>, engine: &Engine) {
        self.deliver(engine);
        self.schedule(engine);
    }

    fn schedule(self: &Rc<Self>, engine: &Engine) {
        let me = Rc::downgrade(self);
        schedule::after(engine, "audit-load", None, TICK, move |engine| {
            let Some(me) = me.upgrade() else {
                return;
            };
            me.tick.set(me.tick.get() + 1);
            // First frames and queued answers before the news, so a
            // subscription opened since the last tick is never sent a
            // delta for a snapshot it has not had.
            me.deliver(engine);
            me.news(engine);
            me.deliver(engine);
            if let Some(after) = me.after_tick.borrow().clone() {
                after(engine);
                me.deliver(engine);
            }
            me.schedule(engine);
        });
    }

    fn first_frame(&self, shape: &Json) -> Option<Json> {
        let tick = self.tick.get();
        match shape["type"].as_str()? {
            "shell" => {
                let mut rows: Vec<Json> = (0..PROJECTS)
                    .map(|p| json!([MC, format!("p{p}"), "project", project(p)]))
                    .collect();
                rows.extend(
                    (0..THREADS).map(|t| json!([MC, format!("t{t}"), "thread", thread(t, tick)])),
                );
                Some(json!({
                    "t": "shell",
                    "mcs": [{"mc": MC, "environment": {"environmentId": ENVIRONMENT, "capabilities": {}},
                             "online": true, "epoch": "e1", "rev": tick + 1}],
                    "rows": rows,
                }))
            }
            "plugins" => {
                let m = &self.manifest;
                Some(json!({"t": "plugins", "plugins": [{
                    "id": PLUGIN,
                    "name": m["name"],
                    "version": m["version"],
                    "revision": self.revision,
                    "status": "running",
                    "icon": m["icon"],
                    "contributes": m["contributes"],
                    "settings": m["settings"],
                }]}))
            }
            "plugin" if shape["topic"] == "threads" => {
                Some(json!({"t": "plugin", "value": reviews(tick)}))
            }
            _ => None,
        }
    }

    /// The tick's news: a few threads moved along, and the reviews again.
    fn news(&self, engine: &Engine) {
        let tick = self.tick.get();
        let rows: Vec<Json> = (0..MOVED)
            .map(|i| (tick * MOVED + i * 13) % THREADS)
            .map(|t| json!([format!("t{t}"), "thread", thread(t, tick)]))
            .collect();
        let frame =
            json!({"t": "shell.rows", "mc": MC, "epoch": "e1", "rev": tick + 1, "rows": rows});
        self.send(engine, |shape| shape["type"] == "shell", &frame);
        let frame = json!({"t": "plugin", "value": reviews(tick)});
        self.send(
            engine,
            |shape| shape["type"] == "plugin" && shape["topic"] == "threads",
            &frame,
        );
    }

    fn send(&self, engine: &Engine, to: impl Fn(&Json) -> bool, frame: &Json) {
        let Json::Object(frame) = frame else {
            return;
        };
        let handlers: Vec<_> = self
            .subscriptions
            .borrow()
            .iter()
            .filter(|s| to(&s.shape))
            .map(|s| (s.id, s.on_frame.clone()))
            .collect();
        for (id, handler) in handlers {
            // An earlier handler may have unsubscribed this one:
            // `Mc::unsubscribe` promises it no further frame.
            if self.subscriptions.borrow().iter().any(|s| s.id == id) {
                (handler.borrow_mut())(engine, frame);
            }
        }
    }

    /// Answers the calls and the new subscriptions, and what they set off.
    pub fn deliver(&self, engine: &Engine) {
        loop {
            let replies = std::mem::take(&mut *self.replies.borrow_mut());
            let fresh = std::mem::take(&mut *self.fresh.borrow_mut());
            if replies.is_empty() && fresh.is_empty() {
                return;
            }
            for (reply, result) in replies {
                reply(engine, result);
            }
            for id in fresh {
                let found = self
                    .subscriptions
                    .borrow()
                    .iter()
                    .find(|s| s.id == id)
                    .map(|s| (s.shape.clone(), s.on_frame.clone()));
                let Some((shape, handler)) = found else {
                    continue;
                };
                if let Some(Json::Object(frame)) = self.first_frame(&shape) {
                    (handler.borrow_mut())(engine, &frame);
                }
            }
        }
    }

    fn answer(&self, method: &str, payload: &Json) -> Result<Json, McError> {
        match method {
            "plugins.file" if payload["id"] == PLUGIN => {
                let path = payload["path"].as_str().unwrap_or_default();
                if !servable(path) {
                    return Err(McError::new("no such file"));
                }
                let bytes = std::fs::read(self.plugin_dir.join(path))
                    .map_err(|e| McError::new(format!("{path}: {e}")))?;
                Ok(match String::from_utf8(bytes) {
                    Ok(text) => json!({"revision": self.revision, "content": text}),
                    Err(e) => json!({
                        "revision": self.revision,
                        "encoding": "base64",
                        "content": base64::Engine::encode(
                            &base64::engine::general_purpose::STANDARD,
                            e.into_bytes()
                        ),
                    }),
                })
            }
            // The rest of the MC is not served: what asks gets what it
            // gets with no MC.
            _ => Err(McError::new("not served by the audit's MC")),
        }
    }
}

impl Mc for Loaded {
    fn is_ready(&self) -> bool {
        true
    }

    fn environment(&self) -> String {
        ENVIRONMENT.into()
    }

    fn call(&self, _: &str, method: &str, payload: Json, reply: Reply) {
        let result = self.answer(method, &payload);
        self.replies.borrow_mut().push((reply, result));
    }

    fn subscribe(&self, shape: Json, on_frame: OnFrame, _: Option<Resume>) -> SubId {
        self.next.set(self.next.get() + 1);
        let id = SubId(self.next.get());
        self.subscriptions.borrow_mut().push(Subscription {
            id,
            shape,
            on_frame: Rc::new(RefCell::new(on_frame)),
        });
        self.fresh.borrow_mut().push(id);
        id
    }

    fn unsubscribe(&self, id: SubId) {
        self.subscriptions.borrow_mut().retain(|s| s.id != id);
        self.fresh.borrow_mut().retain(|fresh| *fresh != id);
    }

    fn more(&self, _: SubId, _: u32) {}

    fn on_ready_changed(&self, _: OnReady) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    fn loaded() -> Rc<Loaded> {
        Rc::new(Loaded {
            plugin_dir: PathBuf::new(),
            manifest: Json::Null,
            revision: "test".into(),
            next: Cell::new(0),
            tick: Cell::new(0),
            subscriptions: RefCell::default(),
            fresh: RefCell::default(),
            replies: RefCell::default(),
            after_tick: RefCell::default(),
        })
    }

    #[test]
    fn only_plain_names_are_served() {
        assert!(servable("ui/ReviewHeader.qml"));
        assert!(servable("plugin.json"));
        assert!(!servable("/etc/passwd"));
        assert!(!servable("../plugin.json"));
        assert!(!servable("ui/../../plugin.json"));
        assert!(!servable("./ui/ReviewHeader.qml"));
        assert!(!servable(""));
    }

    #[test]
    fn reviews_carry_the_plugins_flat_fields() {
        let reviews = reviews(0);
        let review = &reviews["t0"];
        assert_eq!(review["number"], 1000);
        assert_eq!(review["url"], "https://example.invalid/pr/1000");
        assert_eq!(review["key"], "audit-org/audit-repo#1000");
        assert!(review.get("pullRequest").is_none());
    }

    #[test]
    fn the_revision_is_made_of_what_is_served() {
        let files = vec![("ui/ReviewHeader.qml".to_owned(), b"one".to_vec())];
        let revision = revision_for("{}", &files);
        assert_eq!(revision, revision_for("{}", &files));
        let edited = vec![("ui/ReviewHeader.qml".to_owned(), b"two".to_vec())];
        assert_ne!(revision, revision_for("{}", &edited));
        assert_ne!(revision, revision_for("{\"name\":1}", &files));
    }

    #[test]
    fn a_missing_manifest_fails_setup() {
        assert!(load_manifest(Path::new("no-such-plugin-dir")).is_err());
    }

    #[test]
    fn a_handler_unsubscribed_by_an_earlier_one_gets_no_frame() {
        let engine = ljos::engine();
        let mc = loaded();
        let second = Rc::new(Cell::new(None::<SubId>));
        let seen = Rc::new(Cell::new(0usize));
        let weak = Rc::downgrade(&mc);
        let cell = second.clone();
        mc.subscribe(
            json!({"type": "shell"}),
            Box::new(move |_, _| {
                if let (Some(mc), Some(id)) = (weak.upgrade(), cell.get()) {
                    mc.unsubscribe(id);
                }
            }),
            None,
        );
        let count = seen.clone();
        let id = mc.subscribe(
            json!({"type": "shell"}),
            Box::new(move |_, _| count.set(count.get() + 1)),
            None,
        );
        second.set(Some(id));
        mc.send(
            &engine,
            |shape| shape["type"] == "shell",
            &json!({"t": "shell.rows"}),
        );
        assert_eq!(seen.get(), 0);
    }

    #[test]
    fn a_fresh_subscription_gets_its_first_frame_before_the_news() {
        let engine = ljos::engine();
        let mut window = ljos::testing::TestWindow::new(&engine, 100.0, 100.0);
        let mc = loaded();
        mc.start(&engine);
        let seen = Rc::new(RefCell::new(Vec::new()));
        let record = seen.clone();
        mc.subscribe(
            json!({"type": "shell"}),
            Box::new(move |_, frame| {
                record
                    .borrow_mut()
                    .push(frame["t"].as_str().unwrap_or_default().to_owned());
            }),
            None,
        );
        window.advance(250).unwrap();
        assert_eq!(*seen.borrow(), ["shell", "shell.rows"]);
    }
}
