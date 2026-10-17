//! `panel`, desktop-qt's RightPanelController: the right panel beside a
//! thread, each thread's own tabs (Diff, Files, Agents, Terminal, Pull
//! requests, Previews, a pull request under review, a device), which one
//! shows, whether it is open or maximized, and the thread details column.
//!
//! Each thread keeps its panel: going to another thread shows that one's,
//! and the last [`STORED_THREADS`] shown are kept in `shell-panel.json`
//! ([`set_store_path`]) with the panel's width, so they come back with the
//! app. Terminal tabs end with the app.
//!
//! The tabs' models are the `Panel` singleton's ([`PanelObject`]): the
//! panel points them at the thread shown and says which one is in view,
//! so only that one asks the MC for anything.
//!
//! What it publishes (`panel`): null off a thread, else
//! `{threadKey, isOpen, transitionMs, activeId, tabs: [{id, kind, title}],
//! width, maximized, detailsOpen, details, canAdd, addReasons}`.

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::LazyLock;

use ljos::prelude::{Engine, ObjectId, QmlObject, Value};
use regex::Regex;
use serde_json::{Map, json};

use crate::bridge::{self, Bridge};
use crate::commands::Commands;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::keybindings::Keymap;
use crate::controllers::layout;
use crate::controllers::menus::{Answer, Item, Menus};
use crate::controllers::navigation::{self, Navigation, Route};
use crate::controllers::settings::Settings;
use crate::controllers::terminals::{self, Terminals};
use crate::controllers::threads;
use crate::controllers::toasts::{self, Toasts};
use crate::json::{self, Json};
use crate::keybindings::command_label;
use crate::sidebar_model;
use crate::store;
use crate::thread_view::agents::AgentsModel;
use crate::thread_view::diff::DiffModel;
use crate::thread_view::previews::ThreadPreviews;
use crate::thread_view::pull_request_review::{PullRequestReview, Review};
use crate::thread_view::pull_requests::{self, ThreadPullRequests};
use crate::thread_view::thread_diff::ThreadDiff;

/// The kinds of tab the panel shows; a terminal, review or device tab's id
/// carries what it shows after its kind.
pub const NATIVE_KINDS: &[&str] = &[
    "diff",
    "files",
    "agents",
    "terminal",
    "pull-requests",
    "previews",
    "pull-request",
    "device",
];
pub const DEFAULT_WIDTH: i32 = 540;
pub const MINIMUM_WIDTH: i32 = 360;
/// How many threads' panels the store keeps.
pub const STORED_THREADS: usize = 100;

const TERMINAL_TAB: &str = "terminal:";
const REVIEW_TAB: &str = "pull-request:";
const DEVICE_TAB: &str = "device:";

/// A tab's kind: "terminal:<group>" is a terminal, and so on; a native
/// tab's id is its kind.
pub fn kind_of(id: &str) -> &str {
    if id.starts_with(TERMINAL_TAB) {
        "terminal"
    } else if id.starts_with(REVIEW_TAB) {
        "pull-request"
    } else if id.starts_with(DEVICE_TAB) {
        "device"
    } else {
        id
    }
}

/// A conversation link that names a project file rather than an address:
/// "src/cart.ts", "src/cart.ts#L12" or "src/cart.ts:12:3", as ThreadView's
/// openLink reads it. None for web, mail and the app's own links.
pub fn file_link(link: &str) -> Option<(String, i32)> {
    static ADDRESS: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"(?i)^(https?|mailto|hal-c2):").expect("a pattern"));
    static ANCHOR: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"#L(\d+)").expect("a pattern"));
    static POSITION: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r":(\d+)(:\d+)?$").expect("a pattern"));
    static FRAGMENT: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"#.*$").expect("a pattern"));
    static POSITIONS: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"(:\d+)+$").expect("a pattern"));
    if ADDRESS.is_match(link) {
        return None;
    }
    let path = match link.get(..7) {
        Some(scheme) if scheme.eq_ignore_ascii_case("file://") => &link[7..],
        _ => link,
    };
    let line = ANCHOR
        .captures(path)
        .or_else(|| POSITION.captures(path))
        .and_then(|c| c[1].parse().ok())
        .unwrap_or(0);
    let path = FRAGMENT.replace(path, "");
    let path = POSITIONS.replace(&path, "");
    let path = bridge::percent_decode(&path);
    (!path.is_empty()).then_some((path, line))
}

/// A review tab's pull request: host, repository and number of
/// "host/repository#number"; number 0 when it names none.
pub fn reviewed_of(key: &str) -> (String, String, i32) {
    let slash = key.find('/');
    let hash = key.rfind('#');
    match (slash, hash) {
        (Some(slash), Some(hash)) if slash > 0 && hash > slash + 1 => (
            key[..slash].to_owned(),
            key[slash + 1..hash].to_owned(),
            key[hash + 1..].parse().unwrap_or(0),
        ),
        _ => (String::new(), String::new(), 0),
    }
}

/// A device tab's host and device: "device:<host>:<device>", each
/// percent-encoded (ThreadDevices::targetOf). None for any other id.
pub fn device_target_of(id: &str) -> Option<(String, String)> {
    let rest = id.strip_prefix(DEVICE_TAB)?;
    let parts: Vec<&str> = rest.split(':').collect();
    match parts[..] {
        [host, device] if !host.is_empty() && !device.is_empty() => {
            Some((bridge::percent_decode(host), bridge::percent_decode(device)))
        }
        _ => None,
    }
}

fn title_of(id: &str) -> String {
    match kind_of(id) {
        // TODO(port): ThreadDevices::titleOf — a device tab is named for its
        // device once the devices are known; "Device" until then.
        "device" => "Device".into(),
        "pull-request" => format!("PR #{}", reviewed_of(&id[REVIEW_TAB.len()..]).2),
        "diff" => "Diff".into(),
        "agents" => "Agents".into(),
        "terminal" => "Terminal".into(),
        "pull-requests" => "Pull requests".into(),
        "previews" => "Previews".into(),
        _ => "Files".into(),
    }
}

/// Whether a stored tab is one the panel can show again: not a terminal,
/// whose terminals ended with the app.
fn known(tab: &str) -> bool {
    match kind_of(tab) {
        "pull-request" => reviewed_of(&tab[REVIEW_TAB.len()..]).2 > 0,
        _ if tab.starts_with(DEVICE_TAB) => device_target_of(tab).is_some(),
        kind => kind != "terminal" && NATIVE_KINDS.contains(&kind),
    }
}

/// One thread's panel.
#[derive(Clone, Debug, Default, PartialEq)]
struct Panel {
    open: bool,
    tabs: Vec<String>,
    active: String,
    maximized: bool,
    details: bool,
    /// The device tabs the user closed: not opened again on their own.
    dismissed: Vec<String>,
}

/// Takes `id` out of `state`; the next tab shows in its place.
fn remove_tab(state: &mut Panel, id: &str) -> bool {
    let Some(at) = state.tabs.iter().position(|t| t == id) else {
        return false;
    };
    state.tabs.remove(at);
    if id.starts_with(DEVICE_TAB) && !state.dismissed.iter().any(|d| d == id) {
        state.dismissed.push(id.to_owned());
    }
    if state.active == id {
        state.active = match state.tabs.len() {
            0 => String::new(),
            n => state.tabs[at.min(n - 1)].clone(),
        };
        if state.tabs.is_empty() {
            state.open = false;
            state.maximized = false;
        }
    }
    true
}

fn text<'a>(row: &'a Map<String, Json>, field: &str) -> &'a str {
    row.get(field).and_then(Json::as_str).unwrap_or("")
}

fn int(value: Option<&Json>) -> Option<i64> {
    value.and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)))
}

/// How a started thread is doing, for the details column's grouping:
/// "running" (working or waiting on the user), "failed", else "finished".
fn relation_status(thread: &sidebar_model::Thread) -> &'static str {
    match sidebar_model::status(thread) {
        "working" | "approval" | "input" => "running",
        "failed" | "limited" => "failed",
        _ => "finished",
    }
}

/// Where the panels are kept; read when the panel is made.
#[derive(Default)]
struct StorePath(RefCell<Option<PathBuf>>);

/// Where the panel keeps each thread's tabs (`shell-panel.json` in the
/// state directory). Call it before the shell starts; none keeps them for
/// this run only.
pub fn set_store_path(engine: &Engine, path: Option<PathBuf>) {
    *engine.extension::<StorePath>().0.borrow_mut() = path;
}

fn write_atomically(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let mut partial = path.as_os_str().to_owned();
    partial.push(".partial");
    std::fs::write(&partial, bytes)?;
    std::fs::rename(&partial, path)
}

pub struct RightPanel {
    bridge: Bridge,
    me: Me<RightPanel>,
    active: bool,
    /// The thread shown, or shown last: away from a thread the tabs keep
    /// what they show, for coming back.
    thread: String,
    on_thread: bool,
    panels: HashMap<String, Panel>,
    /// What the panel last opened on its own for each thread, so it does
    /// once.
    proactive: HashMap<String, String>,
    /// The threads shown, latest last.
    recent: Vec<String>,
    width: i32,
    store_path: Option<PathBuf>,
    saved: Vec<u8>,
    published_thread: String,
    published_open: bool,
    diff: Option<ObjectId>,
    previews: Option<ObjectId>,
    agents: Option<ObjectId>,
    pull_requests: Option<ObjectId>,
    review: Option<ObjectId>,
    /// The thread's checkout, for the Files tab.
    files_root: String,
}

/// Runs `f` on the panel once it is free.
fn later(engine: &Engine, me: &Me<RightPanel>, f: impl FnOnce(&mut RightPanel, &Engine) + 'static) {
    let me = me.clone();
    Bridge::of(engine).defer(engine, move |engine| me.run(engine, f));
}

fn toast(engine: &Engine, kind: &str, title: &str, description: &str) {
    let (kind, title, description) = (kind.to_owned(), title.to_owned(), description.to_owned());
    Bridge::of(engine).defer(engine, move |engine| {
        controller::with::<Toasts, _>(engine, |t, e| {
            t.show(
                e,
                &kind,
                &title,
                &description,
                None,
                toasts::DEFAULT_TIMEOUT_MS,
            )
        });
    });
}

fn warn<T>(engine: &Engine, result: Result<T, ljos_engine::EngineError>) {
    if let Err(e) = result {
        engine.log(ljos_engine::LogLevel::Warning, "Panel", e.to_string());
    }
}

impl Controller for RightPanel {
    fn new(init: Init<'_, Self>) -> Self {
        let engine = init.engine;
        let me = init.me;
        let owner = engine.singleton::<PanelObject>().ok();
        let diff = ThreadDiff::create(engine, owner, init.mc.clone(), toast);
        let previews = ThreadPreviews::create(engine, owner, init.mc.clone(), toast, |e, url| {
            Bridge::of(e).open_external(e, url)
        });
        let agents = AgentsModel::create(engine, owner, Default::default());
        let pull_requests = ThreadPullRequests::create(
            engine,
            owner,
            init.mc.clone(),
            toast,
            |e, url| Bridge::of(e).open_external(e, url),
            |e, text| Bridge::of(e).copy_to_clipboard(e, text),
        );
        // This pin's copy_to_clipboard says nothing of whether it copied;
        // the next one returns it, and this hands that on.
        let review = PullRequestReview::create(
            engine,
            owner,
            init.mc.clone(),
            toast,
            |e, url| Bridge::of(e).open_external(e, url),
            |e, text| {
                Bridge::of(e).copy_to_clipboard(e, text);
                true
            },
        );
        let (diff, previews, agents) = (diff.ok(), previews.ok(), agents.ok());
        let (pull_requests, review) = (pull_requests.ok(), review.ok());
        if let Some(obj) = owner {
            let value = |obj: Option<ObjectId>| obj.map_or(Value::Null, Value::Object);
            warn(
                engine,
                engine.set_internal(obj, PanelObject::DIFF, value(diff)),
            );
            warn(
                engine,
                engine.set_internal(obj, PanelObject::PREVIEWS, value(previews)),
            );
            warn(
                engine,
                engine.set_internal(obj, PanelObject::AGENTS, value(agents)),
            );
            warn(
                engine,
                engine.set_internal(obj, PanelObject::PULL_REQUESTS, value(pull_requests)),
            );
            warn(
                engine,
                engine.set_internal(obj, PanelObject::REVIEW, value(review)),
            );
        }
        if let Some(previews) = previews {
            // The pages this device opened from a browser tab, kept with its
            // preferences.
            ThreadPreviews::set_recents(
                engine,
                previews,
                |e| {
                    Settings::of(e)
                        .device_value("previewRecentPages")
                        .and_then(|v| serde_json::from_value(v).ok())
                        .unwrap_or_default()
                },
                |e, urls| {
                    Settings::of(e).write_device(e, "previewRecentPages", json!(urls));
                },
            );
        }
        if let Some(diff) = diff {
            // A note on the diff's lines joins the prompt.
            warn(
                engine,
                engine.connect_by_name(diff, "commentRequested", |e, args| {
                    let comment = args.first().map_or(Json::Null, |v| json::from_value(e, v));
                    Bridge::of(e).defer(e, move |e| {
                        Bridge::of(e).dispatch(e, "composer.reviewComment.add", comment)
                    });
                }),
            );
        }
        // TODO(port): ThreadDevices::opened / closed / namesChanged — the
        // devices open and close their tabs (`open_device`, `close_tab_in`)
        // and rename them.
        if let Some(obj) = pull_requests {
            // The add menu and the palette follow the linked pull requests,
            // and the review its environment going offline and back.
            let hook = me.clone();
            warn(
                engine,
                engine.connect_by_name(obj, "countChanged", move |e, _| {
                    later(e, &hook, |p, e| {
                        p.present_commands(e);
                        p.publish(e);
                        p.open_proactively(e);
                    })
                }),
            );
            let hook = me.clone();
            warn(
                engine,
                engine.connect_by_name(obj, "onlineChanged", move |e, _| {
                    later(e, &hook, Self::update)
                }),
            );
        }
        let hook = me.clone();
        store::on_changed(engine, move |e| {
            later(e, &hook, |p, e| {
                if p.active {
                    p.retarget(e)
                }
            })
        });
        let mut panel = RightPanel {
            bridge: init.bridge,
            me,
            active: false,
            thread: String::new(),
            on_thread: false,
            panels: HashMap::new(),
            proactive: HashMap::new(),
            recent: Vec::new(),
            width: DEFAULT_WIDTH,
            store_path: None,
            saved: Vec::new(),
            published_thread: String::new(),
            published_open: false,
            diff,
            previews,
            agents,
            pull_requests,
            review,
            files_root: String::new(),
        };
        let path = engine.extension::<StorePath>().0.borrow().clone();
        panel.load(path);
        panel
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let me = self.me.clone();
        self.bridge
            .watch(engine, "route", move |e, _| later(e, &me, Self::retarget));
        let me = self.me.clone();
        threads::on_active_changed(engine, move |e| later(e, &me, Self::retarget));
        // Diffs wrap long lines as Settings → Appearance says, until the
        // user says otherwise in the panel.
        self.follow_settings(engine);
        let me = self.me.clone();
        Settings::of(engine).on_device_changed(move |e| {
            later(e, &me, |p, e| {
                p.follow_settings(e);
                p.open_proactively(e);
            })
        });
        if let Some(diff) = self.diff {
            let me = self.me.clone();
            warn(
                engine,
                engine.connect_by_name(diff, "turnsChanged", move |e, _| {
                    later(e, &me, Self::open_proactively)
                }),
            );
        }
        // The layout toggle in a diff's toolbar changes the setting too.
        for model in self.diff_models(engine) {
            warn(
                engine,
                engine.connect_by_name(model, "splitChanged", move |e, _| {
                    let split = e.get(model, DiffModel::SPLIT).unwrap_or(false);
                    let layout = if split { "split" } else { "stacked" };
                    Bridge::of(e).defer(e, move |e| {
                        let settings = Settings::of(e);
                        let now = settings.setting(e, "diffLayout");
                        if now.as_ref().and_then(Json::as_str) != Some(layout) {
                            settings.set(e, "diffLayout", json!(layout));
                        }
                    });
                }),
            );
        }
        // Its panel groups come and go with their terminals.
        let me = self.me.clone();
        terminals::on_changed(engine, move |e| later(e, &me, Self::update));
        self.add_commands(engine);
        self.retarget(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !self.active {
            return false;
        }
        let field = |name: &str| {
            payload
                .get(name)
                .and_then(Json::as_str)
                .unwrap_or("")
                .to_owned()
        };
        match action {
            "rightPanel.toggle" => self.toggle(engine),
            "link.menu" => self.link_menu(engine, payload),
            "rightPanel.activate" => self.show_tab(engine, &field("id")),
            "rightPanel.close" => self.close_tab(engine, &field("id")),
            "rightPanel.add" => self.add_tab(engine, &field("kind")),
            "rightPanel.resize" => match payload.get("width").and_then(Json::as_f64) {
                Some(width) => self.set_width(engine, width.round() as i32),
                None => self.reset_width(engine),
            },
            "rightPanel.toggleMaximized" => self.toggle_maximized(engine),
            "threadPanel.toggle" => self.toggle_details(engine),
            "rightPanel.review" => self.review_pull_request(engine, &field("key")),
            "rightPanel.linkPullRequest" => {
                // A pull request a message mentions: the tab shows it once
                // it is linked.
                if self.on_thread {
                    self.show_tab(engine, "pull-requests");
                    if let Some(obj) = self.pull_requests {
                        ThreadPullRequests::link(engine, obj, &field("url"));
                    }
                }
            }
            "rightPanel.reviewProject" => {
                // A pull request of the thread's project that is not linked
                // to it.
                if self.on_thread {
                    self.show_tab(engine, &format!("{REVIEW_TAB}{}", field("key")));
                }
            }
            "rightPanel.openThread" => self.open_thread(engine, &field("threadKey")),
            "panel.open" => self.open(engine, &field("tab"), payload),
            _ => return false,
        }
        true
    }
}

impl RightPanel {
    fn current(&self) -> Panel {
        self.panels.get(&self.thread).cloned().unwrap_or_default()
    }

    fn panel(&mut self) -> &mut Panel {
        self.panels.entry(self.thread.clone()).or_default()
    }

    pub fn is_open(&self) -> bool {
        self.on_thread && self.current().open
    }

    pub fn active_tab(&self) -> String {
        self.current().active
    }

    pub fn tab_ids(&self) -> Vec<String> {
        self.current().tabs
    }

    pub fn is_maximized(&self) -> bool {
        self.is_open() && self.current().maximized
    }

    pub fn details_open(&self) -> bool {
        self.on_thread && self.current().details
    }

    pub fn width(&self) -> i32 {
        self.width
    }

    fn add_commands(&self, engine: &Engine) {
        let commands = Commands::of(engine);
        let add = |command: &str, title: &str, f: fn(&mut RightPanel, &Engine)| {
            let me = self.me.clone();
            commands.add(engine, command, title, move |e| later(e, &me, f));
        };
        let labelled = |command: &str, f: fn(&mut RightPanel, &Engine)| {
            add(command, &command_label(command), f)
        };
        labelled("rightPanel.toggle", Self::toggle);
        // mod+w closes the innermost thing: the active tab, else the window.
        labelled("rightPanel.close", |p, e| {
            let state = p.current();
            if p.on_thread && state.open && !state.active.is_empty() {
                p.close_tab(e, "");
            } else {
                p.bridge.window_command(e, "close");
            }
        });
        labelled("rightPanel.toggleMaximized", Self::toggle_maximized);
        labelled("threadPanel.toggle", Self::toggle_details);
        labelled("diff.toggle", Self::toggle_diff);
        labelled("preview.toggle", Self::toggle_previews);
        labelled("pullRequest.copyNumber", |p, e| {
            if let Some(review) = p.review
                && p.is_open()
                && kind_of(&p.active_tab()) == "pull-request"
            {
                PullRequestReview::update(e, review, Review::copy_number);
            }
        });
        add(
            "thread.showPullRequests",
            "Show linked pull requests",
            |p, e| {
                if p.pull_request_count(e) > 0 {
                    p.show_tab(e, "pull-requests");
                }
            },
        );
        add(
            "thread.linkPullRequest",
            "Link pull request to thread",
            Self::link_pull_request,
        );
        commands.set_terms(
            "thread.showPullRequests",
            &["pull requests", "linked", "stack", "prs"],
        );
        commands.set_terms(
            "thread.linkPullRequest",
            &["link", "pull request", "pr", "attach", "stack"],
        );
    }

    /// Diffs follow Settings → Appearance's wordWrap and Settings →
    /// General's diff defaults.
    fn follow_settings(&mut self, engine: &Engine) {
        let settings = Settings::of(engine);
        let flag = |key: &str| {
            settings
                .setting(engine, key)
                .and_then(|v| v.as_bool())
                .unwrap_or(false)
        };
        let wrap = flag("wordWrap");
        let ignore = flag("diffIgnoreWhitespace");
        let split = settings
            .setting(engine, "diffLayout")
            .is_some_and(|v| v.as_str() == Some("split"));
        let collapsed = flag("diffFilesCollapsed");
        // TODO(port): WorkspaceFiles::setDefaultWrap — file previews wrap
        // as the diffs do.
        if let Some(diff) = self.diff {
            ThreadDiff::update(engine, diff, |t| {
                t.set_default_wrap(wrap);
                t.set_default_ignore_whitespace(ignore);
            });
        }
        for model in self.diff_models(engine) {
            DiffModel::update(engine, model, |d| {
                d.set_split(split);
                d.set_collapsed_by_default(collapsed);
            });
        }
    }

    // --- Where it is ---------------------------------------------------------------

    fn retarget(&mut self, engine: &Engine) {
        let thread_key = match navigation::shown(engine) {
            Route::Thread(key) => key,
            _ => String::new(),
        };
        self.on_thread = !thread_key.is_empty();
        if self.on_thread {
            self.thread = thread_key.clone();
            self.recent.retain(|k| *k != thread_key);
            self.recent.push(thread_key.clone());
            let (environment, rest) = thread_key.split_once(':').unwrap_or(("", &thread_key));
            let (thread_id, root, configured, mc) = store::with(engine, |s| {
                let row = s.thread_row(&thread_key).cloned().unwrap_or_default();
                let thread_id = text(&row, "id");
                let thread_id = if thread_id.is_empty() {
                    rest
                } else {
                    thread_id
                }
                .to_owned();
                let project = s
                    .project_row(environment, text(&row, "projectId"))
                    .cloned()
                    .unwrap_or_default();
                let mut root = text(&row, "worktreePath").to_owned();
                if root.is_empty() {
                    root = text(&project, "workspaceRoot").to_owned();
                }
                // The project's own preview addresses (its scripts'
                // previewUrl).
                let configured: Vec<String> = project
                    .get("scripts")
                    .and_then(Json::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(|script| script.get("previewUrl").and_then(Json::as_str))
                    .filter(|url| !url.is_empty())
                    .map(str::to_owned)
                    .collect();
                (thread_id, root, configured, s.mc_serving(environment))
            });
            let timeline = threads::timeline_of(engine, &thread_key);
            if let Some(diff) = self.diff {
                ThreadDiff::set_thread(engine, diff, environment, &thread_id, timeline);
                ThreadDiff::update(engine, diff, |t| t.set_checkout(&root));
            }
            if let Some(agents) = self.agents {
                AgentsModel::set_thread(engine, agents, environment, timeline);
            }
            // TODO(port): WorkspaceFiles::setTarget(environment, root) and
            // setTimeline(timeline).
            self.files_root = root;
            if let Some(obj) = self.pull_requests {
                ThreadPullRequests::set_thread(engine, obj, &thread_key);
            }
            if let Some(previews) = self.previews {
                ThreadPreviews::update(engine, previews, |p| {
                    p.set_thread(environment, &thread_id, &mc);
                    p.set_configured(configured);
                });
            }
            // TODO(port): ThreadDevices::setThread(environment, threadId, mc).
            self.open_proactively(engine);
        }
        self.present_commands(engine);
        self.update(engine);
    }

    fn open_proactively(&mut self, engine: &Engine) {
        if !self.active || !self.on_thread {
            return;
        }
        let enabled = Settings::of(engine)
            .setting(engine, "proactivePanelsEnabled")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        if !enabled {
            return;
        }
        // Linked pull requests first: the one there is, else their list.
        let links = self
            .pull_requests
            .and_then(|obj| ThreadPullRequests::read(engine, obj, |p| p.keys()))
            .unwrap_or_default();
        let mut target = links.join("\n");
        if target.is_empty() {
            // Otherwise the latest turn's diff, when it changed at least 3
            // files or 50 lines.
            let checkpoint = self
                .diff
                .and_then(|diff| ThreadDiff::read(engine, diff, |t| t.latest_checkpoint()))
                .unwrap_or_default();
            let files = checkpoint
                .get("files")
                .and_then(Json::as_array)
                .cloned()
                .unwrap_or_default();
            let lines: i64 = files
                .iter()
                .map(|f| {
                    int(f.get("additions")).unwrap_or(0) + int(f.get("deletions")).unwrap_or(0)
                })
                .sum();
            if files.len() >= 3 || lines >= 50 {
                target = format!("diff:{}", text(&checkpoint, "id"));
            }
        }
        if target.is_empty() || self.proactive.get(&self.thread) == Some(&target) {
            return;
        }
        self.proactive.insert(self.thread.clone(), target.clone());
        if target.starts_with("diff:") {
            // A pull request under review keeps the panel.
            let state = self.current();
            if !(state.open && kind_of(&state.active) == "pull-request") {
                self.show_tab(engine, "diff");
            }
        } else if links.len() == 1 {
            self.review_pull_request(engine, &links[0]);
        } else {
            self.show_tab(engine, "pull-requests");
        }
    }

    /// The palette offers linking where the thread's environment links pull
    /// requests to threads, and showing them where it keeps a thread's list,
    /// as long as there is one to show.
    fn present_commands(&self, engine: &Engine) {
        if !self.active {
            return;
        }
        let thread_key = match navigation::shown(engine) {
            Route::Thread(key) => key,
            _ => String::new(),
        };
        let environment = thread_key.split_once(':').map_or("", |(e, _)| e);
        let (many, one) = if thread_key.is_empty() {
            (false, false)
        } else {
            store::with(engine, |s| {
                (
                    s.supports(environment, "threadPullRequests"),
                    s.supports(environment, "threadPullRequestLinking"),
                )
            })
        };
        let commands = Commands::of(engine);
        commands.set_listed(engine, "thread.linkPullRequest", many || one);
        commands.set_enabled(engine, "thread.linkPullRequest", many || one);
        commands.set_listed(engine, "thread.showPullRequests", many);
        commands.set_enabled(
            engine,
            "thread.showPullRequests",
            many && self.pull_request_count(engine) > 0,
        );
    }

    /// The thread's linked pull requests.
    fn pull_request_count(&self, engine: &Engine) -> usize {
        self.pull_requests
            .and_then(|obj| ThreadPullRequests::read(engine, obj, |p| p.count()))
            .unwrap_or(0)
    }

    /// The diffs the panel shows: the Diff tab's and a review's.
    fn diff_models(&self, engine: &Engine) -> Vec<ObjectId> {
        let diff = self.diff.and_then(|d| ThreadDiff::model(engine, d));
        let review = self
            .review
            .and_then(|r| PullRequestReview::model(engine, r));
        diff.into_iter().chain(review).collect()
    }

    /// The shown thread's terminal groups in the panel; none while the
    /// terminals are busy.
    fn terminal_groups(&self, engine: &Engine) -> Option<Vec<String>> {
        controller::with::<Terminals, _>(engine, |t, _| t.panel_groups(&self.thread))
    }

    // --- Tabs ----------------------------------------------------------------------

    pub fn toggle(&mut self, engine: &Engine) {
        let open = !self.is_open();
        self.set_open(engine, open);
    }

    pub fn set_open(&mut self, engine: &Engine, open: bool) {
        if !self.on_thread {
            return;
        }
        let state = self.panel();
        if open {
            if state.tabs.is_empty() {
                state.tabs.push("diff".into());
                state.active = "diff".into();
            } else if !state.tabs.contains(&state.active) {
                state.active = state.tabs[0].clone();
            }
        }
        state.open = open;
        // A closed panel comes back beside the thread.
        if !open {
            state.maximized = false;
        }
        self.update(engine);
    }

    /// Shows the Diff (a turn's, a file of it) or the Files tab (a file at
    /// a line): `{path, only, line, turn, turnId}`.
    pub fn open(&mut self, engine: &Engine, tab: &str, options: &Json) {
        if !self.on_thread || (tab != "diff" && tab != "files") {
            return;
        }
        self.show_tab(engine, tab);
        let path = options.get("path").and_then(Json::as_str).unwrap_or("");
        if tab == "diff" {
            let Some(diff) = self.diff else { return };
            let turn = int(options.get("turn")).unwrap_or(0) as i32;
            let run = options.get("turnId").and_then(Json::as_str).unwrap_or("");
            let only = options.get("only").and_then(Json::as_bool).unwrap_or(false);
            ThreadDiff::update(engine, diff, |t| {
                if turn > 0 {
                    t.select(turn);
                } else if !run.is_empty() {
                    t.select_run(run);
                }
                // One file of the turn is shown alone; the turn's diff
                // shows them all.
                if only {
                    t.focus_file(path);
                } else {
                    t.show_all_files();
                    if !path.is_empty() {
                        t.reveal_file(path);
                    }
                }
            });
        } else if !path.is_empty() {
            // TODO(port): WorkspaceFiles::openFile(path, line).
        }
    }

    pub fn show_tab(&mut self, engine: &Engine, id: &str) {
        if !self.on_thread || id.is_empty() {
            return;
        }
        let groups = self.terminal_groups(engine).unwrap_or_default();
        let state = self.panel();
        let allowed = match kind_of(id) {
            "terminal" => groups.iter().any(|g| *g == id[TERMINAL_TAB.len()..]),
            "pull-request" => reviewed_of(&id[REVIEW_TAB.len()..]).2 > 0,
            _ if id.starts_with(DEVICE_TAB) => device_target_of(id).is_some(),
            kind => NATIVE_KINDS.contains(&kind),
        };
        if !allowed {
            return;
        }
        if !state.tabs.iter().any(|t| t == id) {
            state.tabs.push(id.to_owned());
        }
        state.active = id.to_owned();
        state.open = true;
        self.update(engine);
    }

    /// Closes tab `id` of the thread `thread_key`, shown or not (a device
    /// that went).
    pub fn close_tab_in(&mut self, engine: &Engine, thread_key: &str, id: &str) {
        if self.on_thread && thread_key == self.thread {
            return self.close_tab(engine, id);
        }
        if let Some(state) = self.panels.get_mut(thread_key)
            && remove_tab(state, id)
        {
            self.save();
        }
    }

    /// Closes tab `id`, or the active one when it is empty.
    pub fn close_tab(&mut self, engine: &Engine, id: &str) {
        if !self.on_thread {
            return;
        }
        let state = self.panel();
        let closing = if !id.is_empty() {
            id.to_owned()
        } else if state.open {
            state.active.clone()
        } else {
            String::new()
        };
        if closing.is_empty() || !state.tabs.contains(&closing) {
            return;
        }
        if kind_of(&closing) != "terminal" {
            if remove_tab(state, &closing) {
                self.update(engine);
            }
            return;
        }
        // Its terminals go too: asked once for all of them.
        let group = closing[TERMINAL_TAB.len()..].to_owned();
        let thread = self.thread.clone();
        let me = self.me.clone();
        let closed = group.clone();
        let accepted: Answer = Rc::new(move |engine| {
            let (thread, closing, group) = (thread.clone(), closing.clone(), closed.clone());
            me.run(engine, move |p, e| {
                if !p.on_thread || thread != p.thread || !remove_tab(p.panel(), &closing) {
                    return;
                }
                controller::with::<Terminals, _>(e, |t, e| t.close_group(e, &group));
                p.update(e);
            });
        });
        controller::with::<Terminals, _>(engine, |t, e| {
            let ids = t.group_terminals(&group);
            t.confirm_close(e, &ids, accepted);
        });
    }

    pub fn add_tab(&mut self, engine: &Engine, kind: &str) {
        if !self.on_thread {
            return;
        }
        match kind {
            "terminal" => {
                // A new terminal of its own, beside the drawer's.
                let thread = self.thread.clone();
                let group = controller::with::<Terminals, _>(engine, |t, e| {
                    (t.thread_key() == thread)
                        .then(|| t.add_panel_group(e))
                        .flatten()
                })
                .flatten();
                if let Some(group) = group {
                    self.show_tab(engine, &format!("{TERMINAL_TAB}{group}"));
                }
            }
            "browser" => {
                // A new browser tab: an empty one on the MC, filled from the
                // Previews tab.
                self.show_tab(engine, "previews");
                if let Some(previews) = self.previews {
                    ThreadPreviews::update(engine, previews, |p| p.new_tab());
                }
            }
            "pull-request" => {
                // The first one still open, else the first.
                let key = self
                    .pull_requests
                    .and_then(|obj| {
                        ThreadPullRequests::read(engine, obj, |p| {
                            let keys = p.keys();
                            (0..keys.len())
                                .find(|&row| p.state(row) == "open")
                                .or((!keys.is_empty()).then_some(0))
                                .map(|row| keys[row].clone())
                        })
                    })
                    .flatten()
                    .unwrap_or_default();
                self.review_pull_request(engine, &key);
            }
            kind if NATIVE_KINDS.contains(&kind) => self.show_tab(engine, kind),
            _ => {}
        }
    }

    /// Shows the device tab `id`; one opened `automatic`ally (a device the
    /// thread started) shows only if the user did not close it.
    pub fn open_device(&mut self, engine: &Engine, id: &str, automatic: bool) {
        if !self.on_thread {
            return;
        }
        let state = self.panel();
        if automatic
            && (state.dismissed.iter().any(|d| d == id) || state.tabs.iter().any(|t| t == id))
        {
            return;
        }
        state.dismissed.retain(|d| d != id);
        // The device takes the picker's place.
        if !state.tabs.iter().any(|t| t == id) {
            if let Some(picker) = state.tabs.iter().position(|t| t == "device") {
                state.tabs[picker] = id.to_owned();
            }
        } else if let Some(picker) = state.tabs.iter().position(|t| t == "device") {
            state.tabs.remove(picker);
        }
        if state.active == "device" {
            state.active = id.to_owned();
        }
        self.show_tab(engine, id);
    }

    pub fn review_pull_request(&mut self, engine: &Engine, key: &str) {
        // Only a linked pull request is reviewed.
        let linked = self
            .pull_requests
            .and_then(|obj| ThreadPullRequests::read(engine, obj, |p| p.index_of(key)))
            .flatten()
            .is_some();
        if key.is_empty() || !linked {
            return;
        }
        self.show_tab(engine, &format!("{REVIEW_TAB}{key}"));
    }

    pub fn set_width(&mut self, engine: &Engine, width: i32) {
        let width = width.max(MINIMUM_WIDTH);
        if width == self.width {
            return;
        }
        self.width = width;
        self.update(engine);
    }

    pub fn reset_width(&mut self, engine: &Engine) {
        self.set_width(engine, DEFAULT_WIDTH);
    }

    pub fn toggle_maximized(&mut self, engine: &Engine) {
        if !self.is_open() {
            return;
        }
        let state = self.panel();
        state.maximized = !state.maximized;
        self.update(engine);
    }

    pub fn toggle_details(&mut self, engine: &Engine) {
        if !self.on_thread {
            return;
        }
        let state = self.panel();
        state.details = !state.details;
        self.update(engine);
    }

    pub fn toggle_diff(&mut self, engine: &Engine) {
        if self.is_open() && self.active_tab() == "diff" {
            self.set_open(engine, false);
        } else {
            self.show_tab(engine, "diff");
        }
    }

    pub fn toggle_previews(&mut self, engine: &Engine) {
        if self.is_open() && self.active_tab() == "previews" {
            self.set_open(engine, false);
        } else {
            self.show_tab(engine, "previews");
        }
    }

    pub fn link_pull_request(&mut self, engine: &Engine) {
        if !self.on_thread {
            return;
        }
        self.show_tab(engine, "pull-requests");
        if let Some(obj) = self.pull_requests {
            ThreadPullRequests::update(engine, obj, |p| p.set_link_open(true));
        }
    }

    pub fn open_thread(&mut self, engine: &Engine, thread_key: &str) {
        if thread_key.is_empty() {
            return;
        }
        let route = Route::Thread(thread_key.to_owned());
        controller::with::<Navigation, _>(engine, |n, e| n.open(e, route));
    }

    /// A link in the conversation: opening and copying it. A path opens in
    /// the files.
    fn link_menu(&mut self, engine: &Engine, payload: &Json) {
        let url = payload
            .get("url")
            .and_then(Json::as_str)
            .unwrap_or("")
            .to_owned();
        let file = file_link(&url);
        let item = |id: &str, label: &str, icon: &str| Item {
            icon: icon.into(),
            ..Item::new(id, label)
        };
        let mut items = vec![
            match file {
                Some(_) => item("open", "Open file", "file"),
                None => item("open", "Open link", "external-link"),
            },
            item(
                "copy",
                if file.is_some() {
                    "Copy path"
                } else {
                    "Copy link"
                },
                "copy",
            ),
        ];
        // A link naming a pull request links it to the thread, where its
        // environment links them.
        let environment = self.thread.split_once(':').map_or("", |(e, _)| e);
        if self.on_thread
            && pull_requests::parse_url(&url).is_some()
            && store::with(engine, |s| {
                s.supports(environment, "threadPullRequests")
                    || s.supports(environment, "threadPullRequestLinking")
            })
        {
            items.push(item(
                "link-pull-request",
                "Link pull request to thread",
                "git-pull-request",
            ));
        }
        let x = payload.get("x").and_then(Json::as_f64).unwrap_or(0.0);
        let y = payload.get("y").and_then(Json::as_f64).unwrap_or(0.0);
        let me = self.me.clone();
        controller::with::<Menus, _>(engine, move |m, e| {
            m.open(e, x, y, items, move |e, id| {
                let bridge = Bridge::of(e);
                match (id, &file) {
                    ("open", None) => bridge.open_external(e, &url),
                    ("open", Some((path, line))) => {
                        let options = json!({"path": path, "line": line});
                        later(e, &me, move |p, e| p.open(e, "files", &options));
                    }
                    ("copy", None) => bridge.copy_to_clipboard(e, &url),
                    ("copy", Some((path, _))) => bridge.copy_to_clipboard(e, path),
                    ("link-pull-request", _) => {
                        let url = url.clone();
                        later(e, &me, move |p, e| {
                            p.show_tab(e, "pull-requests");
                            if let Some(obj) = p.pull_requests {
                                ThreadPullRequests::link(e, obj, &url);
                            }
                        });
                    }
                    _ => {}
                }
            })
        });
    }

    // --- Out -----------------------------------------------------------------------

    fn update(&mut self, engine: &Engine) {
        if self.on_thread {
            let groups = self.terminal_groups(engine);
            let state = self.panel();
            // A terminal tab whose terminals all ended (here, in another
            // client, or the MC's) goes: the next one shows.
            let before = state.tabs.clone();
            if let Some(groups) = groups {
                state.tabs.retain(|id| {
                    kind_of(id) != "terminal"
                        || groups.iter().any(|g| *g == id[TERMINAL_TAB.len()..])
                });
            }
            if kind_of(&state.active) == "terminal" && !state.tabs.contains(&state.active) {
                let at = before.iter().position(|t| *t == state.active).unwrap_or(0);
                state.active = match state.tabs.len() {
                    0 => String::new(),
                    n => state.tabs[at.min(n - 1)].clone(),
                };
                if state.tabs.is_empty() {
                    state.open = false;
                }
            }
            if !state.open {
                state.maximized = false;
            }
        }
        let open = self.is_open();
        let active = self.active_tab();
        if let Some(diff) = self.diff {
            ThreadDiff::update(engine, diff, |t| t.set_active(open && active == "diff"));
        }
        if let Some(previews) = self.previews {
            ThreadPreviews::update(engine, previews, |p| {
                p.set_active(open && active == "previews")
            });
        }
        if let Some(agents) = self.agents {
            AgentsModel::set_active(engine, agents, open && active == "agents");
        }
        // TODO(port): WorkspaceFiles::setActive, ThreadDevices::setTab.
        // The review shows the active review tab's pull request, or the last
        // one shown.
        if let Some(review) = self.review {
            let reviewing = kind_of(&active) == "pull-request";
            if self.on_thread && reviewing {
                let (host, repository, number) = reviewed_of(&active[REVIEW_TAB.len()..]);
                let online = self
                    .pull_requests
                    .and_then(|obj| ThreadPullRequests::read(engine, obj, |p| p.online()))
                    .unwrap_or(false);
                let environment = self.thread.split_once(':').map_or("", |(e, _)| e);
                let project = store::with(engine, |s| {
                    s.thread_row(&self.thread)
                        .map(|row| text(row, "projectId").to_owned())
                        .unwrap_or_default()
                });
                PullRequestReview::update(engine, review, |r| {
                    r.set_online(online);
                    r.set_pull_request(environment, &project, &host, &repository, number.into());
                });
            }
            PullRequestReview::update(engine, review, |r| r.set_active(open && reviewing));
        }
        Keymap::of(engine).set_preview_open(engine, open && active == "previews");
        self.publish(engine);
        self.save();
    }

    fn publish(&mut self, engine: &Engine) {
        if !self.on_thread {
            self.published_thread.clear();
            self.bridge.publish(engine, "panel", Json::Null);
            return;
        }
        let state = self.current();
        // Opening or closing within a thread slides for as long as the user
        // set; a thread's own layout, shown on arriving, snaps.
        let transition_ms =
            if self.thread == self.published_thread && state.open != self.published_open {
                layout::panel_animation_ms(engine)
            } else {
                0
            };
        self.published_thread = self.thread.clone();
        self.published_open = state.open;
        let tabs: Vec<Json> = state
            .tabs
            .iter()
            .map(|id| json!({"id": id, "kind": kind_of(id), "title": title_of(id)}))
            .collect();
        // Terminals need the thread's place.
        let thread = &self.thread;
        let can_terminal = controller::with::<Terminals, _>(engine, |t, _| {
            t.available() && t.thread_key() == thread
        })
        .unwrap_or(false);
        let files = !self.files_root.is_empty();
        let pull_requests = self.pull_request_count(engine) > 0;
        let reason = |ok: bool, why: &str| if ok { String::new() } else { why.to_owned() };
        let details = if state.details {
            self.thread_details(engine)
        } else {
            Json::Null
        };
        self.bridge.publish(
            engine,
            "panel",
            json!({
                "threadKey": self.thread,
                "isOpen": state.open,
                "transitionMs": transition_ms,
                "activeId": state.active,
                "tabs": tabs,
                "width": self.width,
                "maximized": state.open && state.maximized,
                "detailsOpen": state.details,
                "details": details,
                "canAdd": {
                    "diff": true,
                    "files": files,
                    "agents": true,
                    "terminal": can_terminal,
                    "pullRequests": pull_requests,
                    "pullRequest": pull_requests,
                    "previews": true,
                    "device": true,
                },
                // Why a kind cannot be added, for the Add menu to show under
                // it.
                "addReasons": {
                    "files": reason(files, "Files are only available when a project is open."),
                    "pullRequests": reason(pull_requests, "No linked pull requests are available for this thread."),
                    "pullRequest": reason(pull_requests, "This thread's branch has no pull request yet."),
                },
            }),
        );
    }

    /// What the thread details column shows of the thread, from the rows
    /// the store holds: where it runs, its checkout, and the threads it came
    /// from or started (its lineage's parent, and every thread whose parent
    /// it is).
    fn thread_details(&self, engine: &Engine) -> Json {
        let key = self.thread.clone();
        let (environment_id, thread_id) = key.split_once(':').unwrap_or((&key, ""));
        store::with(engine, |s| {
            let row = s.thread_row(&key).cloned().unwrap_or_default();
            let project = s
                .project_row(environment_id, text(&row, "projectId"))
                .cloned()
                .unwrap_or_default();
            let environment = s.environment(environment_id);
            let worktree = text(&row, "worktreePath");
            let title_of = |id: &str| {
                let title = s
                    .thread_row(&format!("{environment_id}:{id}"))
                    .map(|r| text(r, "title").to_owned())
                    .unwrap_or_default();
                if title.is_empty() {
                    "Unavailable thread".to_owned()
                } else {
                    title
                }
            };
            let lineage_of = |row: &Map<String, Json>| {
                row.get("lineage")
                    .and_then(Json::as_object)
                    .cloned()
                    .unwrap_or_default()
            };
            let lineage = lineage_of(&row);
            let mut relations = Vec::new();
            let parent = text(&lineage, "parentThreadId");
            if !parent.is_empty() {
                let relation = if text(&lineage, "relationshipToParent") == "subagent" {
                    "Started as a subagent of"
                } else {
                    "Forked from"
                };
                relations.push(json!({
                    "threadKey": format!("{environment_id}:{parent}"),
                    "title": title_of(parent),
                    "relation": relation,
                }));
            }
            for thread in s.threads() {
                if thread.environment_id != environment_id || thread.archived_at.is_some() {
                    continue;
                }
                let child = s
                    .thread_row(&thread.key())
                    .map_or_else(Map::new, lineage_of);
                if text(&child, "parentThreadId") != thread_id {
                    continue;
                }
                relations.push(json!({
                    "threadKey": thread.key(),
                    "title": thread.title,
                    "relation": if thread.subagent { "Subagent" } else { "Fork" },
                    "status": relation_status(&thread),
                }));
            }
            let label = text(&environment, "label");
            json!({
                "environment": if label.is_empty() { environment_id } else { label },
                "online": s.thread_online(&key),
                "project": text(&project, "title"),
                "folder": if worktree.is_empty() { text(&project, "workspaceRoot") } else { worktree },
                "checkout": if worktree.is_empty() { "Local" } else { "Worktree" },
                "branch": text(&row, "branch"),
                "relations": relations,
            })
        })
    }

    // --- Kept ----------------------------------------------------------------------

    // The store: {width, threads: [{threadKey, open, tabs, active, details,
    // dismissed (device tabs the user closed)}]}, the thread shown latest
    // last.

    fn load(&mut self, path: Option<PathBuf>) {
        self.store_path = path;
        let Some(bytes) = self.store_path.as_ref().and_then(|p| std::fs::read(p).ok()) else {
            return;
        };
        let stored: Json = serde_json::from_slice(&bytes).unwrap_or(Json::Null);
        self.saved = bytes;
        let width = int(stored.get("width")).map_or(DEFAULT_WIDTH, |w| w as i32);
        self.width = width.max(MINIMUM_WIDTH);
        let threads = stored
            .get("threads")
            .and_then(Json::as_array)
            .cloned()
            .unwrap_or_default();
        for thread in &threads {
            let thread_key = thread.get("threadKey").and_then(Json::as_str).unwrap_or("");
            if thread_key.is_empty() {
                continue;
            }
            let strings = |field: &str| -> Vec<String> {
                thread
                    .get(field)
                    .and_then(Json::as_array)
                    .into_iter()
                    .flatten()
                    .map(|v| v.as_str().unwrap_or("").to_owned())
                    .collect()
            };
            let mut state = Panel::default();
            for tab in strings("tabs") {
                if known(&tab) && !state.tabs.contains(&tab) {
                    state.tabs.push(tab);
                }
            }
            state.active = thread
                .get("active")
                .and_then(Json::as_str)
                .unwrap_or("")
                .to_owned();
            if !state.tabs.contains(&state.active) {
                state.active = state.tabs.first().cloned().unwrap_or_default();
            }
            let flag = |field: &str| thread.get(field).and_then(Json::as_bool).unwrap_or(false);
            state.open = flag("open") && !state.tabs.is_empty();
            state.details = flag("details");
            state.dismissed = strings("dismissed");
            self.panels.insert(thread_key.to_owned(), state);
            self.recent.retain(|k| k != thread_key);
            self.recent.push(thread_key.to_owned());
        }
    }

    fn save(&mut self) {
        let Some(path) = self.store_path.clone() else {
            return;
        };
        let mut threads = Vec::new();
        for thread_key in self.recent.iter().rev() {
            if threads.len() >= STORED_THREADS {
                break;
            }
            let state = self.panels.get(thread_key).cloned().unwrap_or_default();
            // Terminal tabs end with the app.
            let tabs: Vec<&String> = state
                .tabs
                .iter()
                .filter(|id| kind_of(id) != "terminal")
                .collect();
            if tabs.is_empty() && !state.details {
                continue;
            }
            let terminal_shown = kind_of(&state.active) == "terminal";
            threads.push(json!({
                "threadKey": thread_key,
                "open": state.open,
                "tabs": tabs,
                "active": if terminal_shown { Json::Null } else { json!(state.active) },
                "details": state.details,
                "dismissed": state.dismissed,
            }));
        }
        threads.reverse();
        let stored = json!({"width": self.width, "threads": threads});
        let Ok(bytes) = serde_json::to_vec(&stored) else {
            return;
        };
        if bytes == self.saved {
            return;
        }
        if write_atomically(&path, &bytes).is_ok() {
            self.saved = bytes;
        }
    }
}

/// The right panel's tab models, as RightPanelController's properties:
///
/// ```qml
/// DiffPanel { diff: Panel.diff }
/// PreviewsPanel { previews: Panel.previews }
/// ```
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "Panel", uncreatable)]
#[ljos::prelude::qml_singleton]
pub struct PanelObject {
    /// The Diff tab's ThreadDiff.
    #[qml(notify, readonly)]
    diff: Value,
    /// The Previews tab's ThreadPreviews.
    #[qml(notify, readonly)]
    previews: Value,
    // TODO(port): WorkspaceFiles — the Files tab's (its FileTreeModel).
    #[qml(readonly)]
    files: Value,
    /// The Agents tab's AgentsModel.
    #[qml(notify, readonly)]
    agents: Value,
    /// A review tab's PullRequestReview.
    #[qml(notify, readonly)]
    review: Value,
    /// The Pull requests tab's ThreadPullRequests.
    #[qml(notify, readonly)]
    pull_requests: Value,
    // TODO(port): ThreadDevices — a device tab's.
    #[qml(readonly)]
    device: Value,
}

impl Default for PanelObject {
    fn default() -> Self {
        PanelObject {
            diff: Value::Null,
            previews: Value::Null,
            files: Value::Null,
            agents: Value::Null,
            review: Value::Null,
            pull_requests: Value::Null,
            device: Value::Null,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_file_link_names_its_path_and_line() {
        assert_eq!(file_link("src/cart.ts"), Some(("src/cart.ts".into(), 0)));
        assert_eq!(
            file_link("src/cart.ts#L12"),
            Some(("src/cart.ts".into(), 12))
        );
        assert_eq!(
            file_link("src/cart.ts:12:3"),
            Some(("src/cart.ts".into(), 12))
        );
        assert_eq!(file_link("FILE:///a%20b.ts:4"), Some(("/a b.ts".into(), 4)));
        assert_eq!(file_link("https://example.com/a.ts"), None);
        assert_eq!(file_link("Mailto:me@example.com"), None);
        assert_eq!(file_link("hal-c2://thread/x"), None);
    }

    #[test]
    fn a_review_key_names_its_pull_request() {
        assert_eq!(
            reviewed_of("github.com/o/r#12"),
            ("github.com".into(), "o/r".into(), 12)
        );
        assert_eq!(reviewed_of("/o/r#12").2, 0);
        assert_eq!(reviewed_of("github.com/#12").2, 0);
        assert_eq!(reviewed_of("github.com/o/r#x").2, 0);
    }

    #[test]
    fn a_device_tab_names_its_host_and_device() {
        assert_eq!(
            device_target_of("device:h%3A1:d"),
            Some(("h:1".into(), "d".into()))
        );
        assert_eq!(device_target_of("device:h"), None);
        assert_eq!(device_target_of("device:h:"), None);
        assert_eq!(device_target_of("device:a:b:c"), None);
        assert_eq!(device_target_of("diff"), None);
    }

    #[test]
    fn closing_the_active_tab_shows_the_next() {
        let mut state = Panel {
            open: true,
            tabs: vec!["diff".into(), "files".into(), "agents".into()],
            active: "files".into(),
            ..Panel::default()
        };
        assert!(remove_tab(&mut state, "files"));
        assert_eq!(state.active, "agents");
        assert!(remove_tab(&mut state, "agents"));
        assert_eq!(state.active, "diff");
        assert!(remove_tab(&mut state, "diff"));
        assert!(!state.open);
        assert_eq!(state.active, "");
        assert!(!remove_tab(&mut state, "diff"));
    }
}
