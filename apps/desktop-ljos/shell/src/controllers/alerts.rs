//! `alerts`, desktop-qt's AlertController: tells the user when a thread
//! finishes or waits on them. It follows the shell's threads, on every
//! machine of the cluster: a thread that completes, asks for approval or
//! input, fails or stops at its usage limit alerts once per change. Threads
//! it first sees (the snapshot after connecting, a machine that joins) are
//! only remembered, so what finished while the client was away stays quiet.
//!
//! This device's `notificationMode` (off, notifications, sound,
//! notifications-and-sound) and `inAppNotificationsEnabled` decide how:
//! while the window has focus, an in-app toast with "Open thread" for any
//! thread but the one shown; without focus, a system notification per thread
//! (a newer one replaces it), which the window's focus clears. Sound follows
//! the mode alone. Turns that finish without focus are counted on the dock or
//! taskbar badge (Ljós's `Platform` badge) until the window has focus again.
//! The rest of the platform side is the [`Presenter`], which main.rs wires
//! to [`crate::notifications`] and tests fake.
//!
//! A thread's alerts can be muted on this device (`mutedAlertThreads`,
//! thread keys): it is still followed, so unmuting alerts only what changes
//! after. The palette's [`TOGGLE_MUTE`] flips it for the thread shown.

use std::collections::{BTreeSet, HashMap};
use std::rc::Rc;

use ljos::prelude::{Engine, Platform, Value};

use crate::bridge::Bridge;
use crate::commands::Commands;
use crate::controller::{self, Controller, Init, Me, Window};
use crate::controllers::navigation::{Navigation, Route};
use crate::controllers::settings::Settings;
use crate::controllers::toasts::{Action, DEFAULT_TIMEOUT_MS, Toasts};
use crate::json::Json;
use crate::mc::Mc;
use crate::sidebar_model;
use crate::store;

pub const TOGGLE_MUTE: &str = "thread.toggleAlerts";
pub const MUTED_KEY: &str = "mutedAlertThreads";

const MUTE: &str = "Mute alerts for this thread";
const UNMUTE: &str = "Unmute alerts for this thread";

/// The platform's side of alerts. Every part is optional, as desktop-qt's
/// struct of functions is: what a platform lacks keeps its default.
pub trait Presenter {
    /// Shows, or replaces, the system notification for thread `key`; false
    /// when the system does not allow it.
    fn show(&self, _key: &str, _title: &str, _body: &str, _silent: bool) -> bool {
        false
    }
    /// Closes every system notification shown.
    fn clear(&self) {}
    /// Whether system notifications may be shown; off closes them, and
    /// clicks on ones still on their way open nothing.
    fn set_enabled(&self, _enabled: bool) {}
    /// `kind` is "completion" or "input".
    fn play(&self, _kind: &str) {}
    /// Whether the system lets the app notify; `None` where it never
    /// refuses. Choosing system notifications while it does not is undone,
    /// with a toast saying how to allow them.
    fn permitted(&self) -> Option<bool> {
        None
    }
}

/// No platform: nothing is shown or played.
struct Quiet;
impl Presenter for Quiet {}

/// A thread as alerts follow it: the shell store's row, reduced.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AlertThread {
    /// `environment:thread`.
    pub key: String,
    pub title: String,
    pub subagent: bool,
    pub archived: bool,
    /// What the sidebar says of it (`sidebar::status`): "ready", "working",
    /// "input", "approval", "limited", ...
    pub status: String,
    pub latest_run: Option<AlertRun>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AlertRun {
    pub run_id: String,
    /// "completed", "failed", ...
    pub status: String,
    /// When it completed, in milliseconds since the epoch
    /// (`sidebar::parseIso` of its `completedAt`).
    pub completed_at: Option<i64>,
}

/// The dock or taskbar badge: how many turns finished since the window last
/// had focus (0 clears it), as desktop-qt's `QGuiApplication::setBadgeNumber`.
fn badge(engine: &Engine, count: u32) {
    Platform::of(engine).set_badge_number(count);
}

pub fn has_system_notifications(mode: &str) -> bool {
    mode == "notifications" || mode == "notifications-and-sound"
}

pub fn has_sound(mode: &str) -> bool {
    mode == "sound" || mode == "notifications-and-sound"
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct Seen {
    /// "runId:status" while the thread waits on the user or stopped.
    attention: String,
    completion: Option<i64>,
}

pub type Locate = Rc<dyn Fn(&Engine, &str) -> String>;

pub struct AlertController {
    bridge: Bridge,
    mc: Rc<dyn Mc>,
    me: Me<Self>,
    presenter: Rc<dyn Presenter>,
    mode: String,
    in_app: bool,
    focused: bool,
    /// Turns finished since the window last had focus.
    unseen: u32,
    seen: HashMap<String, Seen>,
    muted: BTreeSet<String>,
    settings_read: bool,
    following_settings: bool,
    /// The store's threads, once it is synchronized; `None` until then.
    threads: Option<Vec<AlertThread>>,
    locate: Option<Locate>,
}

impl Controller for AlertController {
    fn new(init: Init<'_, Self>) -> Self {
        let engine = init.engine;
        let me = init.me.clone();
        // A reconnect's snapshot is a new baseline: what finished meanwhile
        // is quiet.
        init.mc.on_ready_changed(Box::new(move |engine, ready| {
            if !ready {
                me.run(engine, |alerts, _| {
                    alerts.seen.clear();
                    // The store hands its threads over again once its
                    // snapshot is in.
                    alerts.threads = None;
                });
            }
        }));
        follow_store(engine, &init.me);
        let focused = follow_focus(engine, &init.me);
        AlertController {
            bridge: init.bridge,
            mc: init.mc,
            me: init.me,
            presenter: Rc::new(Quiet),
            mode: "off".to_owned(),
            in_app: false,
            focused,
            unseen: 0,
            seen: HashMap::new(),
            muted: BTreeSet::new(),
            settings_read: false,
            following_settings: false,
            threads: None,
            locate: Some(Rc::new(|engine: &Engine, key: &str| {
                store::get(engine).map_or_else(|| key.to_owned(), |s| s.borrow().located(key))
            })),
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if !self.following_settings {
            self.following_settings = true;
            let me = self.me.clone();
            Settings::of(engine).on_device_changed(move |engine| {
                me.run(engine, |alerts, engine| alerts.read_settings(engine));
            });
        }
        self.read_settings(engine);
        self.evaluate(engine);
    }

    fn attach(&mut self, engine: &Engine, _window: &Window) {
        let commands = Commands::of(engine);
        let me = self.me.clone();
        commands.add(engine, TOGGLE_MUTE, MUTE, move |engine| {
            let key = shown(engine);
            me.run(engine, |alerts, engine| {
                if !key.is_empty() {
                    let muted = alerts.is_muted(&key);
                    alerts.set_muted(engine, &key, !muted);
                }
            });
        });
        commands.set_terms(TOGGLE_MUTE, &["mute", "unmute", "notifications", "alerts"]);
        // Its title follows the route. Watchers run inside the publish, so
        // the presenting waits until no controller runs.
        let me = self.me.clone();
        self.bridge.watch(engine, "route", move |engine, _| {
            let me = me.clone();
            Bridge::of(engine).defer(engine, move |engine| {
                me.run(engine, |alerts, engine| alerts.present(engine));
            });
        });
        self.present(engine);
    }
}

/// Hands the store's threads over on each change once it is synchronized
/// with its MCs, after the change has run.
fn follow_store(engine: &Engine, me: &Me<AlertController>) {
    let me = me.clone();
    store::on_changed(engine, move |engine| {
        let me = me.clone();
        Bridge::of(engine).defer(engine, move |engine| {
            let threads = store::with(engine, |s| {
                s.synchronized().then(|| {
                    s.threads()
                        .iter()
                        .map(|t| AlertThread {
                            key: t.key(),
                            title: t.title.clone(),
                            subagent: t.subagent,
                            archived: t.archived_at.is_some(),
                            status: sidebar_model::status(t).to_owned(),
                            latest_run: t.latest_run.as_ref().map(|run| AlertRun {
                                run_id: run.run_id.clone(),
                                status: run.status.clone(),
                                completed_at: sidebar_model::parse_iso(run.completed_at.as_deref()),
                            }),
                        })
                        .collect::<Vec<_>>()
                })
            });
            if let Some(threads) = threads {
                me.run(engine, |alerts, engine| alerts.set_threads(engine, threads));
            }
        });
    });
}

/// Whether the application has focus, followed from Ljós's `Application`
/// (`Qt.application`); focused when there is none.
fn follow_focus(engine: &Engine, me: &Me<AlertController>) -> bool {
    let Ok(app) = engine.singleton::<ljos_controls::Application>() else {
        return true;
    };
    let me = me.clone();
    let _ = engine.connect_by_name(app, "activeChanged", move |engine, _| {
        let active = matches!(engine.read_by_name(app, "active"), Value::Bool(true));
        me.run(engine, |alerts, engine| alerts.set_focused(engine, active));
    });
    !matches!(engine.read_by_name(app, "active"), Value::Bool(false))
}

/// The thread the window shows; empty when it shows none.
fn shown(engine: &Engine) -> String {
    controller::with::<Navigation, _>(engine, |navigation, _| match navigation.route() {
        Route::Thread(key) => key.clone(),
        _ => String::new(),
    })
    .unwrap_or_default()
}

fn open(engine: &Engine, key: &str) -> bool {
    controller::with::<Navigation, _>(engine, |navigation, engine| {
        navigation.open(engine, Route::Thread(key.to_owned()));
    })
    .is_some()
}

impl AlertController {
    pub fn set_presenter(&mut self, presenter: Rc<dyn Presenter>) {
        self.presenter = presenter;
        self.presenter
            .set_enabled(has_system_notifications(&self.mode));
    }

    /// The store's threads, now that it is synchronized with its MCs; each
    /// change of the store hands them over again.
    pub fn set_threads(&mut self, engine: &Engine, threads: Vec<AlertThread>) {
        self.threads = Some(threads);
        self.evaluate(engine);
    }

    /// Where a thread lives now, from where it lived when it was notified
    /// (it may have moved since). The store's `located`, unless tests say.
    pub fn set_locate(&mut self, locate: Locate) {
        self.locate = Some(locate);
    }

    /// Whether the window has focus; the application's unless tests say.
    pub fn focused(&self) -> bool {
        self.focused
    }

    pub fn set_focused(&mut self, engine: &Engine, focused: bool) {
        if self.focused == focused {
            return;
        }
        self.focused = focused;
        // Back at the window, the system notifications have done their job.
        if focused {
            self.presenter.clear();
        }
        if focused && self.unseen > 0 {
            self.unseen = 0;
            badge(engine, 0);
        }
    }

    /// A system notification for `key` was clicked: shows its thread in the
    /// window the user last acted in and raises that window. False when
    /// system notifications are off or the thread is gone.
    pub fn open_thread(&mut self, engine: &Engine, notified: &str) -> bool {
        // A notification from before the thread moved opens it where it
        // lives now.
        let key = match &self.locate {
            Some(locate) => locate(engine, notified),
            None => notified.to_owned(),
        };
        let known = self
            .threads
            .as_ref()
            .is_some_and(|threads| threads.iter().any(|t| t.key == key));
        if !has_system_notifications(&self.mode) || !known {
            return false;
        }
        if !open(engine, &key) {
            return false;
        }
        self.bridge.window_command(engine, "raise");
        true
    }

    pub fn is_muted(&self, key: &str) -> bool {
        self.muted.contains(key)
    }

    /// Mutes or unmutes thread `key`'s alerts on this device.
    pub fn set_muted(&mut self, engine: &Engine, key: &str, muted: bool) {
        if key.is_empty() || self.is_muted(key) == muted {
            return;
        }
        if muted {
            self.muted.insert(key.to_owned());
        } else {
            self.muted.remove(key);
        }
        let keys: Vec<Json> = self.muted.iter().cloned().map(Json::String).collect();
        Settings::of(engine).write_device(engine, MUTED_KEY, Json::Array(keys));
        self.present(engine);
    }

    /// Keeps [`TOGGLE_MUTE`]'s title to the thread shown, and lists it only
    /// while one is.
    fn present(&self, engine: &Engine) {
        let key = shown(engine);
        let commands = Commands::of(engine);
        commands.set_title(
            engine,
            TOGGLE_MUTE,
            if self.is_muted(&key) { UNMUTE } else { MUTE },
        );
        commands.set_listed(engine, TOGGLE_MUTE, !key.is_empty());
    }

    fn read_settings(&mut self, engine: &Engine) {
        let settings = Settings::of(engine);
        let mode = settings
            .setting(engine, "notificationMode")
            .and_then(|v| v.as_str().map(str::to_owned))
            .unwrap_or_default();
        self.in_app = settings
            .setting(engine, "inAppNotificationsEnabled")
            .is_some_and(|v| v == Json::Bool(true));
        let next: BTreeSet<String> = settings
            .device_value(MUTED_KEY)
            .and_then(|v| v.as_array().cloned())
            .unwrap_or_default()
            .into_iter()
            .filter_map(|v| v.as_str().map(str::to_owned))
            .collect();
        if next != self.muted {
            self.muted = next;
            self.present(engine);
        }
        let chosen = std::mem::replace(&mut self.settings_read, true);
        if mode == self.mode {
            // In-app alerts just turned on follow the threads as they are
            // now.
            if self.seen.is_empty() {
                self.evaluate(engine);
            }
            return;
        }
        // Chosen now (not what this device already held) while the system
        // refuses: the choice is undone, and the user told how to allow it.
        if chosen
            && has_system_notifications(&mode)
            && !has_system_notifications(&self.mode)
            && self.presenter.permitted() == Some(false)
        {
            settings.set(engine, "notificationMode", Json::String(self.mode.clone()));
            controller::with::<Toasts, _>(engine, |toasts, engine| {
                toasts.show(
                    engine,
                    "warning",
                    "Notifications are not allowed",
                    "Allow notifications for HAL-C2 in your system settings, then choose this \
                     option again. Sound only is still available.",
                    None,
                    DEFAULT_TIMEOUT_MS,
                );
            });
            return;
        }
        self.mode = mode;
        self.presenter.clear();
        self.presenter
            .set_enabled(has_system_notifications(&self.mode));
        // Alerts just turned on follow the threads as they are now.
        if self.seen.is_empty() {
            self.evaluate(engine);
        }
    }

    fn evaluate(&mut self, engine: &Engine) {
        if !self.mc.is_ready() {
            return;
        }
        let Some(threads) = self.threads.clone() else {
            return;
        };
        // With every alert off nothing is followed; turning one on starts
        // afresh.
        if self.mode == "off" && !self.in_app {
            self.seen.clear();
            return;
        }
        let shown = shown(engine);

        let mut next = HashMap::new();
        for thread in &threads {
            if thread.subagent {
                continue;
            }
            let key = thread.key.clone();
            let run = thread.latest_run.as_ref();
            let mut status = thread.status.as_str();
            if status == "ready" && run.is_some_and(|r| r.status == "failed") {
                status = "failed";
            }
            let prior = self.seen.get(&key);
            let mut seen = Seen::default();
            if matches!(status, "input" | "approval" | "failed" | "limited") {
                let run_id = run.map_or("", |r| r.run_id.as_str());
                seen.attention = format!("{run_id}:{status}");
            }
            let completed_at = run.and_then(|r| r.completed_at);
            if status == "ready"
                && run.is_some_and(|r| r.status == "completed")
                && completed_at.is_some()
            {
                seen.completion = completed_at;
            } else if let Some(prior) = prior {
                seen.completion = prior.completion;
            }
            next.insert(key.clone(), seen.clone());
            let Some(prior) = prior else { continue };
            if thread.archived || self.muted.contains(&key) {
                continue;
            }

            let kind = if !seen.attention.is_empty() && seen.attention != prior.attention {
                "input"
            } else if seen
                .completion
                .is_some_and(|at| prior.completion.is_none_or(|before| at > before))
            {
                "completion"
            } else {
                continue;
            };
            let title = if kind == "completion" {
                "Thread completed"
            } else {
                match status {
                    "approval" => "Approval needed",
                    "limited" => "Usage limit reached",
                    "failed" => "Thread failed",
                    _ => "Input needed",
                }
            };
            if has_sound(&self.mode) {
                self.presenter.play(kind);
            }
            if kind == "completion" && !self.focused {
                self.unseen += 1;
                badge(engine, self.unseen);
            }
            if self.in_app && self.focused && key != shown {
                let kind_of_toast = if kind == "completion" {
                    "success"
                } else if status == "failed" {
                    "error"
                } else {
                    "warning"
                };
                let open_key = key.clone();
                let action = Action::new("Open thread", move |engine| {
                    open(engine, &open_key);
                });
                controller::with::<Toasts, _>(engine, |toasts, engine| {
                    toasts.show(
                        engine,
                        kind_of_toast,
                        title,
                        &thread.title,
                        Some(action),
                        DEFAULT_TIMEOUT_MS,
                    );
                });
                continue;
            }
            if !has_system_notifications(&self.mode) || self.focused {
                continue;
            }
            // The sound, when there is one, is the mode's own, not the
            // system's.
            self.presenter.show(&key, title, &thread.title, true);
        }
        self.seen = next;
    }
}

/// What a test reads of the alerts it drove.
impl AlertController {
    pub fn mode(&self) -> &str {
        &self.mode
    }

    pub fn unseen(&self) -> u32 {
        self.unseen
    }
}
