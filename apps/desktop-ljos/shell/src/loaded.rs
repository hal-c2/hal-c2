//! `--audit --load`: an MC that keeps the shell busy the way a working day
//! does, so the audit judges the shell loaded rather than empty. It serves
//! one environment of [`PROJECTS`] projects and [`THREADS`] threads (some
//! pinned, some running, one waiting on a question) and the code-review
//! plugin, read from the checkout's `plugins/code-review`; then, every
//! [`TICK`] of the engine's clock, a `shell.rows` frame that moves a few
//! threads along and a publish of the plugin's `threads` topic, a value of
//! one entry a thread, as its MC part publishes it.
//!
//! Everything it sends is made from the tick's number, and it runs on the
//! engine's clock, so the load is the same on every run and on every
//! machine; it ends when the audit stops letting time pass.

use std::cell::{Cell, RefCell};
use std::path::PathBuf;
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
/// The text of a review in the plugin's value: a review's summary is about
/// this long.
const SUMMARY: usize = 1500;

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
/// thread.
fn reviews(tick: usize) -> Json {
    let mut out = serde_json::Map::new();
    for t in (0..THREADS).filter(|t| t.is_multiple_of(4)) {
        let status = ["queued", "running", "waiting", "published"][(t + tick) % 4];
        out.insert(
            format!("t{t}"),
            json!({
                "status": status,
                "pullRequest": {"number": 1000 + t, "url": format!("https://example.invalid/pr/{}", 1000 + t)},
                "verdict": if (t + tick).is_multiple_of(3) { "approve" } else { "comment" },
                "summary": format!("Review {tick} of thread {t}. ").repeat(SUMMARY / 24),
                "comments": (0..8).map(|c| json!({"path": format!("src/file_{c}.rs"), "line": c * 10 + tick % 10, "body": "A finding about this line."})).collect::<Vec<_>>(),
            }),
        );
    }
    Json::Object(out)
}

struct Subscription {
    id: SubId,
    shape: Json,
    on_frame: Rc<RefCell<OnFrame>>,
}

/// The loaded MC; [`Loaded::start`] after the shell starts.
pub struct Loaded {
    plugin_dir: PathBuf,
    next: Cell<u64>,
    tick: Cell<usize>,
    subscriptions: RefCell<Vec<Subscription>>,
    /// Subscriptions that have not had their first frame.
    fresh: RefCell<Vec<SubId>>,
    replies: RefCell<Vec<(Reply, Result<Json, McError>)>>,
}

impl Loaded {
    pub fn new() -> Rc<Loaded> {
        Rc::new(Loaded {
            plugin_dir: PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../../../plugins/code-review"),
            next: Cell::new(0),
            tick: Cell::new(0),
            subscriptions: RefCell::default(),
            fresh: RefCell::default(),
            replies: RefCell::default(),
        })
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
            me.news(engine);
            me.deliver(engine);
            me.schedule(engine);
        });
    }

    fn manifest(&self) -> Json {
        std::fs::read_to_string(self.plugin_dir.join("plugin.json"))
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or(Json::Null)
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
                let m = self.manifest();
                Some(json!({"t": "plugins", "plugins": [{
                    "id": PLUGIN,
                    "name": m["name"],
                    "version": m["version"],
                    "revision": "audit-1",
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
            .map(|s| s.on_frame.clone())
            .collect();
        for handler in handlers {
            (handler.borrow_mut())(engine, frame);
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
                if path.split('/').any(|part| part == "..") {
                    return Err(McError::new("no such file"));
                }
                let bytes = std::fs::read(self.plugin_dir.join(path))
                    .map_err(|e| McError::new(format!("{path}: {e}")))?;
                Ok(match String::from_utf8(bytes) {
                    Ok(text) => json!({"revision": "audit-1", "content": text}),
                    Err(e) => json!({
                        "revision": "audit-1",
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
    }

    fn more(&self, _: SubId, _: u32) {}

    fn on_ready_changed(&self, _: OnReady) {}
}
