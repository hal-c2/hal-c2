//! desktop-qt's ThreadMenuController: a thread's action menu, from its
//! sidebar row (`thread.menu {key, x, y}`) and from the header's title
//! (`workspace.titleMenu {x, y}`, the route's thread, or its draft's menu).
//! Items are the thread's actions, plus Fork and Move to another machine;
//! the environment's capabilities leave items out and an offline
//! environment turns the ones that need it off. Each action toasts its
//! failure, and the ones that hide a thread (archive, unpin, settle, snooze)
//! offer Undo.
//!
//! With several threads selected ([`sidebar::selection`]), the menu of one
//! of them is the selection's: each action names how many threads it
//! touches ("Unpin (1)", "Settle (3)") and applies to all of them. Deleting
//! keeps the threads that could not be deleted selected.
//!
//! The route thread's keybinding commands (thread.pin, thread.settle) run
//! here too ([`ThreadMenu::toggle_pin`], [`ThreadMenu::toggle_settle`]), and
//! it registers the palette's own for the route thread:
//! thread.copyReference, projectSettings.open and thread.move (a menu of the
//! cluster's other machines, listed while there is one).
//!
//! A move asks what `hal-c2.moveThread` asks (what stays behind, which
//! project) where it was started: the menu's point, or the palette. A thread
//! whose agent is working is not moved by the MC, so the user is offered to
//! stop the turn first; the move is sent once the thread's row shows it idle.
//!
//! A menu's choice runs once no controller is running, so most of this is
//! free functions; what the controller keeps is the moves waiting on a stop
//! and the palette's project choices.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::commands::{Choice, Commands};
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::drafts;
use crate::controllers::menus::{Answer, Item, Menus};
use crate::controllers::navigation::{self, Navigation, Route};
use crate::controllers::settings::Settings;
use crate::controllers::sidebar::{self, Leave, Sidebar, Then};
use crate::controllers::toasts::{DEFAULT_TIMEOUT_MS, Toasts};
use crate::json::Json;
use crate::keybindings::command_label;
use crate::sidebar_model::{self as model, Thread};
use crate::store;

pub const COPY_REFERENCE: &str = "thread.copyReference";
pub const PROJECT_SETTINGS_COMMAND: &str = "projectSettings.open";
pub const MOVE: &str = "thread.move";
/// The palette's menu of the projects a move may go into; never listed.
const MOVE_PROJECT: &str = "thread.move.project";
/// The settings page for projects.
const PROJECT_SETTINGS: &str = "/settings/projects";

/// Writes the clipboard; false when it could not.
pub type ClipboardWriter = Rc<dyn Fn(&Engine, &str) -> bool>;

/// threadRuntimeCanArchive: an agent that is starting or working keeps the
/// thread.
fn running(thread: &Thread) -> bool {
    let Some(runtime) = &thread.runtime else {
        return false;
    };
    matches!(
        runtime.status.as_str(),
        "preparing" | "starting" | "running"
    ) || (runtime.status == "queued" && runtime.active_run_id.is_some())
}

/// What the MC does not move: a thread with a turn under way or a question
/// open.
fn busy(thread: &Thread) -> bool {
    running(thread)
        || thread.active_run_id.is_some()
        || thread.has_pending_approvals
        || thread.has_pending_user_input
}

/// A machine as a move offers it. Labels are the user's own and may repeat:
/// one that does among `offered` is told apart by its environment id.
fn machine_name(label: &str, environment_id: &str, offered: &[String]) -> String {
    if offered.iter().filter(|l| *l == label).count() > 1 {
        format!("{label} · {environment_id}")
    } else {
        label.to_owned()
    }
}

fn setting(engine: &Engine, key: &str) -> bool {
    Settings::of(engine).setting(engine, key) == Some(Json::Bool(true))
}

fn thread(engine: &Engine, key: &str) -> Option<Thread> {
    store::with(engine, |s| s.thread(key))
}

fn row_text(engine: &Engine, key: &str, field: &str) -> String {
    store::with(engine, |s| {
        s.thread_row(key)
            .and_then(|r| r.get(field))
            .and_then(Json::as_str)
            .unwrap_or_default()
            .to_owned()
    })
}

fn project_root(engine: &Engine, thread: &Thread) -> String {
    store::with(engine, |s| {
        s.project_row(&thread.environment_id, &thread.project_id)
            .and_then(|r| r.get("workspaceRoot"))
            .and_then(Json::as_str)
            .unwrap_or_default()
            .to_owned()
    })
}

fn regenerating(engine: &Engine, key: &str) -> bool {
    store::with(engine, |s| {
        s.thread_row(key)
            .is_some_and(|r| r.get("titleRegeneration").is_some_and(Json::is_object))
    })
}

fn toasts<R: Default>(engine: &Engine, f: impl FnOnce(&mut Toasts, &Engine) -> R) -> R {
    controller::with::<Toasts, _>(engine, f).unwrap_or_default()
}

fn toast_error(engine: &Engine, title: &str, reason: &str) {
    toasts(engine, |t, e| {
        t.error(e, title, reason);
    });
}

fn show(engine: &Engine, kind: &str, title: &str, description: &str, timeout_ms: i64) -> String {
    toasts(engine, |t, e| {
        t.show(e, kind, title, description, None, timeout_ms)
    })
}

fn dismiss(engine: &Engine, id: &str) {
    toasts(engine, |t, e| t.dismiss(e, id));
}

fn confirm(
    engine: &Engine,
    title: &str,
    description: &str,
    label: &str,
    destructive: bool,
    accepted: Answer,
    declined: Option<Answer>,
) {
    controller::with::<Menus, _>(engine, |m, e| {
        m.confirm(
            e,
            title,
            description,
            label,
            destructive,
            Some(accepted),
            declined,
        );
    });
}

fn open_menu(
    engine: &Engine,
    x: f64,
    y: f64,
    items: Vec<Item>,
    chosen: impl Fn(&Engine, &str) + 'static,
) {
    controller::with::<Menus, _>(engine, |m, e| {
        m.open(e, x, y, items, chosen);
    });
}

fn open_route(engine: &Engine, route: Route) {
    controller::with::<Navigation, _>(engine, |n, e| n.open(e, route));
}

fn with_sidebar(engine: &Engine, f: impl FnOnce(&mut Sidebar, &Engine)) {
    controller::with::<Sidebar, _>(engine, f);
}

fn dispatch(engine: &Engine, action: &str, key: &str) {
    Bridge::of(engine).dispatch(engine, action, json!({"key": key}));
}

/// Sends the thread `key`'s `command`; a failure toasts `failure_title`.
fn command(engine: &Engine, key: &str, command: Json, failure_title: &str, then: Option<Then>) {
    let Some(thread) = thread(engine, key) else {
        return;
    };
    sidebar::command(engine, &thread.environment_id, command, failure_title, then);
}

/// Sends each thread's command; `done` gets the keys that failed and the
/// first failure's reason once every answer is in.
fn command_each(
    engine: &Engine,
    keys: &[String],
    make: impl Fn(&str) -> Json,
    done: impl FnOnce(&Engine, Vec<String>, String) + 'static,
) {
    let targets: Vec<(String, Thread)> = keys
        .iter()
        .filter_map(|k| thread(engine, k).map(|t| (k.clone(), t)))
        .collect();
    if targets.is_empty() {
        done(engine, Vec::new(), String::new());
        return;
    }
    let Some(mc) = controller::mc(engine) else {
        return;
    };
    type Done = Box<dyn FnOnce(&Engine, Vec<String>, String)>;
    struct Batch {
        pending: Cell<usize>,
        failed: RefCell<Vec<String>>,
        reason: RefCell<String>,
        done: RefCell<Option<Done>>,
    }
    let batch = Rc::new(Batch {
        pending: Cell::new(targets.len()),
        failed: RefCell::default(),
        reason: RefCell::default(),
        done: RefCell::new(Some(Box::new(done))),
    });
    for (key, thread) in targets {
        let batch = batch.clone();
        mc.dispatch_command(
            &thread.environment_id,
            make(&thread.id),
            Box::new(move |engine, result| {
                if let Err(error) = result {
                    if batch.failed.borrow().is_empty() {
                        *batch.reason.borrow_mut() = error.message;
                    }
                    batch.failed.borrow_mut().push(key);
                }
                batch.pending.set(batch.pending.get() - 1);
                if batch.pending.get() == 0
                    && let Some(done) = batch.done.borrow_mut().take()
                {
                    done(
                        engine,
                        batch.failed.borrow().clone(),
                        batch.reason.borrow().clone(),
                    );
                }
            }),
        );
    }
}

fn snooze_item(engine: &Engine, label: String, enabled: bool) -> Item {
    let mut snooze = Item::new("snooze", label);
    snooze.icon = "clock".into();
    snooze.enabled = enabled;
    snooze.children = sidebar::snooze_items(&sidebar::snooze_presets(engine));
    snooze
}

fn item(id: &str, label: impl Into<String>, icon: &str) -> Item {
    let mut item = Item::new(id, label);
    item.icon = icon.into();
    item
}

/// Where a move's questions are asked: a menu at the point, or the palette.
#[derive(Clone, Copy, Debug, Default)]
struct Asking {
    x: f64,
    y: f64,
    palette: bool,
}

/// Where a thread moves to: the environment id is what is sent and the
/// label what is shown.
#[derive(Clone, Debug)]
struct Machine {
    id: String,
    label: String,
}

/// A move waiting for its thread's turn to stop.
struct Stopping {
    machine: Machine,
    asking: Asking,
    toast: String,
}

pub struct ThreadMenu {
    me: Me<Self>,
    write_clipboard: ClipboardWriter,
    stopping: HashMap<String, Stopping>,
    /// The projects a move from the palette may go into, and the move.
    project_choices: Rc<RefCell<Vec<Choice>>>,
}

impl Controller for ThreadMenu {
    fn new(init: Init<'_, Self>) -> Self {
        ThreadMenu {
            me: init.me,
            write_clipboard: Rc::new(|engine: &Engine, text: &str| {
                // TODO(ljos#N): Clipboard::set_text says nothing of a
                // failure, so a copy always says it was copied.
                Bridge::of(engine).set_clipboard(engine, text);
                true
            }),
            stopping: HashMap::new(),
            project_choices: Rc::default(),
        }
    }

    fn activate(&mut self, engine: &Engine) {
        let commands = Commands::of(engine);
        commands.add(
            engine,
            COPY_REFERENCE,
            &command_label(COPY_REFERENCE),
            |engine| {
                let key = route_thread(engine);
                if !key.is_empty() {
                    controller::with::<ThreadMenu, _>(engine, |m, e| m.copy_reference(e, &key));
                }
            },
        );
        commands.set_terms(
            COPY_REFERENCE,
            &["copy", "pull request", "pr link", "thread id", "reference"],
        );
        commands.add(
            engine,
            PROJECT_SETTINGS_COMMAND,
            "Project settings",
            |engine| {
                let key = route_thread(engine);
                if !key.is_empty() {
                    open_project_settings(engine, &key);
                }
            },
        );
        commands.set_terms(
            PROJECT_SETTINGS_COMMAND,
            &["project", "settings", "scripts", "configuration"],
        );
        // The cluster's other machines, as the shell lists them.
        commands.add_menu(engine, MOVE, "Move to another machine", |engine| {
            let key = route_thread(engine);
            let Some(thread) = thread(engine, &key) else {
                return Vec::new();
            };
            let mut machines: Vec<Choice> = store::with(engine, |s| {
                s.environments()
                    .into_iter()
                    .filter(|id| *id != thread.environment_id)
                    .map(|id| {
                        let label = s
                            .environment(&id)
                            .get("label")
                            .and_then(Json::as_str)
                            .filter(|l| !l.is_empty())
                            .unwrap_or(&id)
                            .to_owned();
                        let machine = Machine {
                            id: id.clone(),
                            label: label.clone(),
                        };
                        let key = key.clone();
                        let mut choice = Choice::new(&id, &label, move |engine| {
                            let machine = machine.clone();
                            let key = key.clone();
                            controller::with::<ThreadMenu, _>(engine, |m, e| {
                                m.start_move(
                                    e,
                                    &key,
                                    machine,
                                    Asking {
                                        palette: true,
                                        ..Asking::default()
                                    },
                                );
                            });
                        });
                        choice.enabled = s.environment_online(&id);
                        if !choice.enabled {
                            choice.description = "Offline".into();
                        }
                        choice.terms = vec![id];
                        choice
                    })
                    .collect()
            });
            let labels: Vec<String> = machines.iter().map(|c| c.title.clone()).collect();
            for choice in &mut machines {
                choice.title = machine_name(&choice.title, &choice.id, &labels);
            }
            machines.sort_by(|a, b| a.title.cmp(&b.title));
            machines
        });
        commands.set_terms(MOVE, &["move", "machine", "cluster", "transfer", "migrate"]);
        let choices = self.project_choices.clone();
        commands.add_menu(engine, MOVE_PROJECT, "Move into project", move |_| {
            choices.borrow().clone()
        });
        commands.set_listed(engine, MOVE_PROJECT, false);
        Bridge::of(engine).watch(engine, "route", |engine, _| {
            Bridge::of(engine).defer(engine, present);
        });
        let me = self.me.clone();
        store::on_changed(engine, move |engine| {
            let me = me.clone();
            Bridge::of(engine).defer(engine, move |engine| {
                present(engine);
                me.run(engine, |m, e| m.move_stopped(e));
            });
        });
        // TODO(port): WorkspaceController::gitChanged — the route thread's
        // branch PR, which "Copy PR link" would copy, is not followed.
        present(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        let x = payload.get("x").and_then(Json::as_f64).unwrap_or_default();
        let y = payload.get("y").and_then(Json::as_f64).unwrap_or_default();
        let key = payload
            .get("key")
            .and_then(Json::as_str)
            .unwrap_or_default()
            .to_owned();
        match action {
            "thread.menu" => open(engine, &key, x, y, false),
            "thread.unpin" => {
                unpin(engine, &key);
                true
            }
            "workspace.titleMenu" => {
                // TODO(port): WorkspaceController::place — the header's
                // place is the route's here.
                match navigation::shown(engine) {
                    Route::Draft(draft_id) => Bridge::of(engine).dispatch(
                        engine,
                        "draft.menu",
                        json!({"draftId": draft_id, "x": x, "y": y}),
                    ),
                    Route::Thread(key) => {
                        open(engine, &key, x, y, true);
                    }
                    _ => {}
                }
                true
            }
            _ => false,
        }
    }
}

impl ThreadMenu {
    /// Writes the clipboard instead of the system's (tests make it fail).
    pub fn set_clipboard_writer(&mut self, write: ClipboardWriter) {
        self.write_clipboard = write;
    }

    /// Puts `value` on the clipboard and says so, or why not.
    pub fn copy(&mut self, engine: &Engine, value: &str, success_title: &str, failure_title: &str) {
        if (self.write_clipboard)(engine, value) {
            show(engine, "success", success_title, value, DEFAULT_TIMEOUT_MS);
        } else {
            toast_error(engine, failure_title, "The clipboard could not be written.");
        }
    }

    /// The thread's current pull request link, else its id.
    pub fn copy_reference(&mut self, engine: &Engine, key: &str) {
        let Some(thread) = thread(engine, key) else {
            return;
        };
        let url = pull_request_url(engine, key);
        if url.is_empty() {
            self.copy(
                engine,
                &thread.id,
                "Thread ID copied",
                "Failed to copy thread ID",
            );
        } else {
            self.copy(engine, &url, "PR link copied", "Failed to copy PR link");
        }
    }

    /// The route thread's thread.pin.
    pub fn toggle_pin(&mut self, engine: &Engine, key: &str) {
        let Some(thread) = thread(engine, key) else {
            return;
        };
        if !store::with(engine, |s| s.capabilities(&thread.environment_id).pinning) {
            return;
        }
        if thread.pinned_at.is_some() {
            unpin(engine, key);
        } else {
            pin(engine, key);
        }
    }

    /// The route thread's thread.settle.
    pub fn toggle_settle(&mut self, engine: &Engine, key: &str) {
        let Some(thread) = thread(engine, key) else {
            return;
        };
        if !store::with(engine, |s| {
            s.capabilities(&thread.environment_id).settlement
        }) {
            return;
        }
        let settled = thread.settled_override.as_deref() == Some("settled");
        dispatch(
            engine,
            if settled {
                "thread.unsettle"
            } else {
                "thread.settle"
            },
            key,
        );
    }

    /// The move the user chose: sent as it is, or after stopping the
    /// thread's turn.
    fn start_move(&mut self, engine: &Engine, key: &str, machine: Machine, asking: Asking) {
        let Some(thread) = thread(engine, key) else {
            return;
        };
        let run_id = thread
            .active_run_id
            .clone()
            .or_else(|| thread.latest_run_id.clone());
        let Some(run_id) = run_id.filter(|_| busy(&thread)) else {
            move_thread(engine, key, machine, String::new(), false, asking);
            return;
        };
        let me = self.me.clone();
        let key = key.to_owned();
        let label = machine.label.clone();
        let accepted: Answer = Rc::new(move |engine: &Engine| {
            let Some(thread) = self::thread(engine, &key) else {
                return;
            };
            let toast = show(
                engine,
                "loading",
                &format!("Stopping \"{}\"…", thread.title),
                "",
                0,
            );
            me.run(engine, |m, _| {
                m.stopping.insert(
                    key.clone(),
                    Stopping {
                        machine: machine.clone(),
                        asking,
                        toast,
                    },
                );
            });
            let me = me.clone();
            let key = key.clone();
            let Some(mc) = controller::mc(engine) else {
                return;
            };
            mc.dispatch_command(
                &thread.environment_id,
                json!({"type": "run.interrupt", "threadId": thread.id, "runId": run_id}),
                Box::new(move |engine, result| {
                    let Err(error) = result else {
                        return;
                    };
                    let mut stopped = None;
                    me.run(engine, |m, _| stopped = m.stopping.remove(&key));
                    if let Some(stopping) = stopped {
                        dismiss(engine, &stopping.toast);
                        toast_error(engine, "Failed to move thread", &error.message);
                    }
                }),
            );
        });
        confirm(
            engine,
            &format!("Stop \"{}\" and move it to {label}?", thread.title),
            "The agent is working in this thread. Its turn is stopped before the thread moves.",
            "Stop and move",
            false,
            accepted,
            None,
        );
    }

    /// Sends the moves that waited for their thread's turn to stop.
    fn move_stopped(&mut self, engine: &Engine) {
        let idle: Vec<String> = self
            .stopping
            .keys()
            .filter(|key| thread(engine, key).is_none_or(|t| !busy(&t)))
            .cloned()
            .collect();
        for key in idle {
            let Some(stopping) = self.stopping.remove(&key) else {
                continue;
            };
            dismiss(engine, &stopping.toast);
            if thread(engine, &key).is_some() {
                let (machine, asking) = (stopping.machine, stopping.asking);
                Bridge::of(engine).defer(engine, move |engine| {
                    move_thread(engine, &key, machine, String::new(), false, asking);
                });
            }
        }
    }
}

/// The thread the window shows, empty when none.
fn route_thread(engine: &Engine) -> String {
    match navigation::shown(engine) {
        Route::Thread(key) => key,
        _ => String::new(),
    }
}

/// Opens the menu of the thread `key` at window coordinates; false when the
/// shell does not know the thread. `header` leaves out the project filter.
pub fn open(engine: &Engine, key: &str, x: f64, y: f64, header: bool) -> bool {
    let Some(thread) = thread(engine, key) else {
        return false;
    };
    let selection = sidebar::selection(engine);
    if !header && selection.len() > 1 && selection.iter().any(|k| k == key) {
        open_selection(engine, selection, x, y);
        return true;
    }
    let (supports, online, environments) = store::with(engine, |s| {
        (
            s.capabilities(&thread.environment_id),
            s.thread_online(key),
            s.environments(),
        )
    });
    let now = sidebar::now_ms(engine);
    let mut items: Vec<Item> = Vec::new();
    // Actions the environment runs are off while it is offline.
    let mut add = |mut item: Item, needs_environment: bool| {
        if needs_environment && !online {
            item.enabled = false;
        }
        items.push(item);
    };
    if let Some(branch) = &thread.branch {
        add(
            item(
                "new-thread-on-branch",
                format!("New thread on {branch}"),
                "message-square-plus",
            ),
            false,
        );
    }
    if supports.pinning {
        add(
            if thread.pinned_at.is_some() {
                item("unpin", "Unpin thread", "pin-off")
            } else {
                item("pin", "Pin thread", "pin")
            },
            true,
        );
    }
    // Arranging, where the thread has a place to move to.
    let (up, down) = (
        sidebar::can_move(engine, key, true),
        sidebar::can_move(engine, key, false),
    );
    if up || down {
        let mut move_up = item("move-up", "Move up", "arrow-up");
        move_up.enabled = up;
        add(move_up, true);
        let mut move_down = item("move-down", "Move down", "arrow-down");
        move_down.enabled = down;
        add(move_down, true);
    }
    if supports.settlement {
        let settled = thread.settled_override.as_deref() == Some("settled");
        add(
            if settled {
                item("unsettle", "Un-settle thread", "circle-check")
            } else {
                item("settle", "Settle thread", "circle-check")
            },
            true,
        );
    }
    if supports.snooze {
        if model::effective_snoozed(&thread, now) {
            add(item("unsnooze", "Wake thread", "clock"), true);
        } else {
            add(
                snooze_item(engine, "Snooze".into(), model::can_snooze(&thread, now)),
                true,
            );
        }
    }
    let mut rename = item("rename", "Rename thread", "pencil");
    rename.separator_before = true;
    add(rename, true);
    if supports.title_regeneration {
        let busy = regenerating(engine, key);
        let mut regenerate = item(
            "regenerate-title",
            if busy {
                "Regenerating…"
            } else {
                "Regenerate title"
            },
            "refresh-cw",
        );
        regenerate.enabled = !busy;
        add(regenerate, true);
    }
    add(item("mark-unread", "Mark unread", "mail-open"), true);
    let project_key =
        sidebar::logical_project_key(engine, &thread.environment_id, &thread.project_id);
    if !header && let Some(project_key) = &project_key {
        let scoped = sidebar::scope(engine).as_ref() == Some(project_key);
        let label = sidebar::group(engine, project_key)
            .and_then(|g| {
                g.summary
                    .get("displayName")
                    .and_then(Json::as_str)
                    .map(str::to_owned)
            })
            .unwrap_or_default();
        add(
            item(
                "filter-by-project",
                if scoped {
                    "Show all projects".to_owned()
                } else {
                    format!("Filter by {label}")
                },
                "folder-tree",
            ),
            false,
        );
    }
    let mut copy = item("copy", "Copy", "copy");
    copy.separator_before = true;
    copy.children.push(item("copy-path", "Path", "folder"));
    if thread.branch.is_some() {
        copy.children
            .push(item("copy-branch", "Branch", "git-branch"));
    }
    copy.children
        .push(item("copy-thread-id", "Thread ID", "hash"));
    copy.children.push(item("copy-link", "Link", "link"));
    add(copy, false);
    if project_key.is_some() {
        add(
            item("project-settings", "Project settings", "settings"),
            false,
        );
    }
    add(item("fork", "Fork thread", "git-fork"), true);
    // Another machine of the cluster can take the thread.
    if environments.iter().any(|e| *e != thread.environment_id) {
        add(
            item("move", "Move to another machine…", "arrow-right-left"),
            true,
        );
    }
    let mut archive = item("archive", "Archive thread", "archive");
    archive.separator_before = true;
    archive.enabled = !running(&thread);
    add(archive, true);
    let mut remove = item("delete", "Delete", "trash");
    remove.destructive = true;
    add(remove, true);
    let key = key.to_owned();
    open_menu(engine, x, y, items, move |engine, id| {
        choose(engine, &key, id, x, y);
    });
    true
}

fn open_selection(engine: &Engine, keys: Vec<String>, x: f64, y: f64) {
    let now = sidebar::now_ms(engine);
    let count = keys.len();
    let (mut pinned, mut regenerable, mut regenerating_count) = (0, 0, 0);
    let (mut snoozable, mut settleable, mut any_running, mut online) = (true, true, false, true);
    for key in &keys {
        let Some(thread) = thread(engine, key) else {
            continue;
        };
        let (supports, thread_online) = store::with(engine, |s| {
            (s.capabilities(&thread.environment_id), s.thread_online(key))
        });
        if supports.pinning && thread.pinned_at.is_some() {
            pinned += 1;
        }
        if supports.title_regeneration {
            if regenerating(engine, key) {
                regenerating_count += 1;
            } else {
                regenerable += 1;
            }
        }
        snoozable = snoozable && supports.snooze && model::can_snooze(&thread, now);
        settleable = settleable && supports.settlement;
        any_running = any_running || running(&thread);
        online = online && thread_online;
    }
    let counted = |label: &str, of: usize| format!("{label} ({of})");
    let mut items = Vec::new();
    let mut add = |mut item: Item| {
        if !online {
            item.enabled = false;
        }
        items.push(item);
    };
    // Each count is what the action touches.
    if pinned > 0 {
        add(item("unpin", counted("Unpin", pinned), "pin-off"));
    }
    if settleable {
        add(item("settle", counted("Settle", count), "circle-check"));
    }
    if snoozable {
        add(snooze_item(engine, counted("Snooze", count), true));
    }
    if regenerable > 0 {
        add(item(
            "regenerate-title",
            counted("Regenerate titles", regenerable),
            "refresh-cw",
        ));
    } else if regenerating_count > 0 {
        let mut busy = item(
            "regenerate-title",
            counted("Regenerating…", regenerating_count),
            "refresh-cw",
        );
        busy.enabled = false;
        add(busy);
    }
    add(item(
        "mark-unread",
        counted("Mark unread", count),
        "mail-open",
    ));
    let mut archive = item("archive", counted("Archive", count), "archive");
    archive.separator_before = true;
    archive.enabled = !any_running;
    add(archive);
    let mut remove = item("delete", counted("Delete", count), "trash");
    remove.destructive = true;
    add(remove);
    open_menu(engine, x, y, items, move |engine, id| {
        choose_for_selection(engine, &keys, id);
    });
}

fn plural(count: usize) -> &'static str {
    if count == 1 { "thread" } else { "threads" }
}

fn typed(kind: &'static str) -> impl Fn(&str) -> Json {
    move |thread_id| json!({"type": kind, "threadId": thread_id})
}

fn choose_for_selection(engine: &Engine, keys: &[String], id: &str) {
    let clear = |engine: &Engine| with_sidebar(engine, |s, e| s.clear_selection(e));
    if id == sidebar::CUSTOM_SNOOZE {
        let keys = keys.to_vec();
        with_sidebar(engine, |s, e| s.ask_custom_snooze(e, keys));
    } else if let Some(preset) = id.strip_prefix("snooze:") {
        let Some(until) = sidebar::snooze_presets(engine)
            .into_iter()
            .find(|p| p.id == preset)
            .map(|p| p.snoozed_until)
        else {
            return;
        };
        clear(engine);
        let total = keys.len();
        command_each(
            engine,
            keys,
            move |thread_id| json!({"type": "thread.snooze", "threadId": thread_id, "snoozedUntil": until}),
            move |engine, failed, reason| {
                if failed.is_empty() {
                    return;
                }
                let title = if failed.len() < total {
                    format!("Failed to snooze {} {}", failed.len(), plural(failed.len()))
                } else {
                    "Failed to snooze threads".to_owned()
                };
                toast_error(engine, &title, &reason);
            },
        );
    } else if id == "unpin" {
        let pinned: Vec<String> = keys
            .iter()
            .filter(|k| thread(engine, k).is_some_and(|t| t.pinned_at.is_some()))
            .cloned()
            .collect();
        clear(engine);
        command_each(
            engine,
            &pinned,
            typed("thread.unpin"),
            |engine, failed, reason| {
                if !failed.is_empty() {
                    toast_error(engine, "Failed to unpin threads", &reason);
                }
            },
        );
    } else if id == "settle" {
        clear(engine);
        for key in keys {
            if thread(engine, key).is_some_and(|t| t.settled_override.as_deref() != Some("settled"))
            {
                dispatch(engine, "thread.settle", key);
            }
        }
    } else if id == "regenerate-title" {
        let eligible: Vec<String> = keys
            .iter()
            .filter(|k| {
                thread(engine, k).is_some_and(|t| {
                    store::with(engine, |s| {
                        s.capabilities(&t.environment_id).title_regeneration
                    }) && !regenerating(engine, k)
                })
            })
            .cloned()
            .collect();
        clear(engine);
        command_each(
            engine,
            &eligible,
            |thread_id| json!({"type": "thread.metadata.update", "threadId": thread_id, "regenerateTitle": true}),
            |engine, failed, reason| {
                if !failed.is_empty() {
                    toast_error(engine, "Failed to regenerate thread titles", &reason);
                }
            },
        );
    } else if id == "mark-unread" {
        clear(engine);
        for key in keys {
            dispatch(engine, "thread.markUnread", key);
        }
    } else if id == "archive" {
        clear(engine);
        for key in keys {
            archive(engine, key);
        }
    } else if id == "delete" {
        let keys = keys.to_vec();
        let count = keys.len();
        let run: Answer = Rc::new(move |engine: &Engine| {
            let keys = keys.clone();
            command_each(
                engine,
                &keys.clone(),
                typed("thread.delete"),
                move |engine, failed, reason| {
                    if !failed.is_empty() {
                        toast_error(engine, "Failed to delete threads", &reason);
                    }
                    // The threads that could not be deleted stay selected.
                    let deleted: Vec<String> =
                        keys.into_iter().filter(|k| !failed.contains(k)).collect();
                    with_sidebar(engine, |s, e| s.deselect(e, &deleted));
                },
            );
        });
        if setting(engine, "confirmThreadDelete") {
            confirm(
                engine,
                &format!("Delete {count} {}?", plural(count)),
                "This permanently clears conversation history for these threads.",
                "Delete",
                true,
                run,
                None,
            );
        } else {
            run(engine);
        }
    }
}

fn choose(engine: &Engine, key: &str, id: &str, x: f64, y: f64) {
    let Some(thread) = thread(engine, key) else {
        return;
    };
    match id {
        sidebar::CUSTOM_SNOOZE => {
            let keys = vec![key.to_owned()];
            with_sidebar(engine, |s, e| s.ask_custom_snooze(e, keys));
        }
        "new-thread-on-branch" => new_thread_on_branch(engine, key),
        "move-up" | "move-down" => Bridge::of(engine).dispatch(
            engine,
            "thread.move",
            json!({"key": key, "direction": if id == "move-up" { "up" } else { "down" }}),
        ),
        "pin" => pin(engine, key),
        "unpin" => unpin(engine, key),
        "settle" => dispatch(engine, "thread.settle", key),
        "unsettle" => dispatch(engine, "thread.unsettle", key),
        "unsnooze" => dispatch(engine, "thread.unsnooze", key),
        "rename" => {
            // The header edits the title; it is on its way there when not open.
            if route_thread(engine) != key {
                open_route(engine, Route::Thread(key.to_owned()));
            }
            Bridge::of(engine).dispatch(
                engine,
                "workspace.rename.begin",
                json!({"threadKey": key}),
            );
        }
        "regenerate-title" => command(
            engine,
            key,
            json!({"type": "thread.metadata.update", "threadId": thread.id, "regenerateTitle": true}),
            "Failed to regenerate thread title",
            None,
        ),
        "mark-unread" => dispatch(engine, "thread.markUnread", key),
        "filter-by-project" => {
            let project_key =
                sidebar::logical_project_key(engine, &thread.environment_id, &thread.project_id);
            let scoped = sidebar::scope(engine) == project_key;
            let to = if scoped { None } else { project_key };
            Bridge::of(engine).dispatch(engine, "sidebar.scope", json!({"projectKey": to}));
        }
        "copy-path" => {
            let path = workspace_path(engine, key);
            if path.is_empty() {
                show(
                    engine,
                    "error",
                    "Path unavailable",
                    "This thread does not have a workspace path to copy.",
                    DEFAULT_TIMEOUT_MS,
                );
            } else {
                copy(engine, &path, "Path copied", "Failed to copy path");
            }
        }
        "copy-branch" => {
            if let Some(branch) = &thread.branch {
                copy(engine, branch, "Branch copied", "Failed to copy branch");
            }
        }
        "copy-thread-id" => copy(
            engine,
            &thread.id,
            "Thread ID copied",
            "Failed to copy thread ID",
        ),
        "copy-link" => copy(
            engine,
            &navigation::thread_link(key),
            "Link copied",
            "Failed to copy link",
        ),
        "project-settings" => open_project_settings(engine, key),
        "fork" => fork(engine, key),
        "move" => choose_destination(engine, key, x, y),
        "archive" => {
            if setting(engine, "confirmThreadArchive") {
                let key = key.to_owned();
                confirm(
                    engine,
                    &format!("Archive thread \"{}\"?", thread.title),
                    "",
                    "Archive",
                    false,
                    Rc::new(move |engine: &Engine| archive(engine, &key)),
                    None,
                );
            } else {
                archive(engine, key);
            }
        }
        "delete" => {
            if setting(engine, "confirmThreadDelete") {
                let key = key.to_owned();
                confirm(
                    engine,
                    &format!("Delete thread \"{}\"?", thread.title),
                    "This permanently clears conversation history for this thread.",
                    "Delete",
                    true,
                    Rc::new(move |engine: &Engine| remove(engine, &key)),
                    None,
                );
            } else {
                remove(engine, key);
            }
        }
        _ => {
            if let Some(preset) = id.strip_prefix("snooze:")
                && let Some(until) = sidebar::snooze_presets(engine)
                    .into_iter()
                    .find(|p| p.id == preset)
                    .map(|p| p.snoozed_until)
            {
                with_sidebar(engine, |s, e| s.snooze(e, key, &until));
            }
        }
    }
}

fn copy(engine: &Engine, value: &str, success_title: &str, failure_title: &str) {
    controller::with::<ThreadMenu, _>(engine, |m, e| {
        m.copy(e, value, success_title, failure_title)
    });
}

/// Archiving moves the window to a new thread in the project when it showed
/// the thread; Undo brings the thread back, and the reader with it.
fn archive(engine: &Engine, key: &str) {
    let Some(thread) = thread(engine, key) else {
        return;
    };
    let viewing = route_thread(engine) == key;
    let (undo_key, environment_id, thread_id) = (
        key.to_owned(),
        thread.environment_id.clone(),
        thread.id.clone(),
    );
    let then: Then = Box::new(move |engine: &Engine| {
        let undo = Rc::new(move |engine: &Engine| {
            let key = undo_key.clone();
            sidebar::command(
                engine,
                &environment_id,
                json!({"type": "thread.unarchive", "threadId": thread_id}),
                "Failed to undo archive",
                Some(Box::new(move |engine: &Engine| {
                    if viewing {
                        open_route(engine, Route::Thread(key));
                    }
                })),
            );
        });
        toasts(engine, |t, e| t.show_undo(e, "Archived", "Archived", undo));
    });
    let key = key.to_owned();
    with_sidebar(engine, |s, e| {
        s.park(
            e,
            &key,
            json!({"type": "thread.archive", "threadId": thread.id}),
            "Failed to archive thread",
            Leave::ProjectDraft,
            Some(then),
        );
    });
}

/// The thread's worktree when no other thread uses it, else empty.
fn orphaned_worktree(engine: &Engine, key: &str) -> String {
    let worktree = row_text(engine, key, "worktreePath").trim().to_owned();
    if worktree.is_empty() {
        return worktree;
    }
    let shared = store::with(engine, |s| {
        s.threads().iter().any(|other| {
            other.key() != key
                && s.thread_row(&other.key())
                    .and_then(|r| r.get("worktreePath"))
                    .and_then(Json::as_str)
                    .is_some_and(|w| w.trim() == worktree)
        })
    });
    if shared { String::new() } else { worktree }
}

fn last_segment(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

/// Deleting the last thread of a worktree offers to remove the worktree too
/// (`vcs.removeWorktree`), or removes it unasked when the cleanup rules say
/// so (storageCleanup.worktreeOnDelete, or the project's own).
fn remove(engine: &Engine, key: &str) {
    let Some(thread) = thread(engine, key) else {
        return;
    };
    let worktree = orphaned_worktree(engine, key);
    if worktree.is_empty() || project_root(engine, &thread).is_empty() {
        remove_with(engine, key, String::new());
        return;
    }
    // The project's own rules, else the environment's.
    let settings = Settings::of(engine);
    let policy = settings
        .value(&format!(
            "projectSettingsOverrides.{}.worktreeCleanup",
            thread.project_id
        ))
        .unwrap_or(Json::Null);
    let automatic = match policy["mode"].as_str().unwrap_or_default() {
        "custom" => policy["rules"]["worktreeOnDelete"] == Json::Bool(true),
        "off" => false,
        _ => settings.value("storageCleanup.worktreeOnDelete") == Some(Json::Bool(true)),
    };
    if automatic {
        remove_with(engine, key, worktree);
        return;
    }
    let (with_key, without_key) = (key.to_owned(), key.to_owned());
    let description = format!(
        "This thread is the only one linked to this worktree: {}",
        last_segment(&worktree)
    );
    confirm(
        engine,
        "Delete the worktree too?",
        &description,
        "Delete worktree",
        true,
        Rc::new(move |engine: &Engine| remove_with(engine, &with_key, worktree.clone())),
        Some(Rc::new(move |engine: &Engine| {
            remove_with(engine, &without_key, String::new());
        })),
    );
}

fn remove_with(engine: &Engine, key: &str, worktree: String) {
    let Some(thread) = thread(engine, key) else {
        return;
    };
    let root = project_root(engine, &thread);
    let clean_up: Option<Then> = (!worktree.is_empty()).then(|| {
        let environment_id = thread.environment_id.clone();
        Box::new(move |engine: &Engine| {
            let Some(mc) = controller::mc(engine) else {
                return;
            };
            let name = last_segment(&worktree).to_owned();
            mc.call(
                &environment_id,
                "vcs.removeWorktree",
                json!({"cwd": root, "path": worktree, "force": true}),
                Box::new(move |engine, result| {
                    if let Err(error) = result {
                        toast_error(
                            engine,
                            "Failed to delete worktree",
                            &format!("Could not remove {name}. {}", error.message),
                        );
                    }
                }),
            );
        }) as Then
    });
    let key = key.to_owned();
    with_sidebar(engine, |s, e| {
        s.park(
            e,
            &key,
            json!({"type": "thread.delete", "threadId": thread.id}),
            "Failed to delete thread",
            Leave::ProjectFallback,
            clean_up,
        );
    });
}

fn pin(engine: &Engine, key: &str) {
    let Some(thread) = thread(engine, key) else {
        return;
    };
    command(
        engine,
        key,
        json!({"type": "thread.pin", "threadId": thread.id}),
        "Failed to pin thread",
        None,
    );
}

fn unpin(engine: &Engine, key: &str) {
    let Some(thread) = thread(engine, key) else {
        return;
    };
    let (run_key, thread_id, order_key) = (
        key.to_owned(),
        thread.id.clone(),
        thread.pin_order_key.clone(),
    );
    let run: Answer = Rc::new(move |engine: &Engine| {
        let (key, pinned_id, order_key) = (run_key.clone(), thread_id.clone(), order_key.clone());
        let then: Then = Box::new(move |engine: &Engine| {
            let undo = Rc::new(move |engine: &Engine| {
                let mut pin = json!({"type": "thread.pin", "threadId": pinned_id});
                if let Some(order) = &order_key {
                    pin["orderKey"] = json!(order);
                }
                command(engine, &key, pin, "Failed to undo unpin", None);
            });
            toasts(engine, |t, e| t.show_undo(e, "Unpinned", "Unpinned", undo));
        });
        command(
            engine,
            &run_key,
            json!({"type": "thread.unpin", "threadId": thread_id}),
            "Failed to unpin thread",
            Some(then),
        );
    });
    if setting(engine, "confirmThreadUnpin") {
        confirm(
            engine,
            &format!("Unpin thread \"{}\"?", thread.title),
            "This will move the thread out of your pinned section.",
            "Unpin",
            false,
            run,
            None,
        );
    } else {
        run(engine);
    }
}

/// The thread's current pull request: the row's linkedPullRequest.
///
/// TODO(port): WorkspaceController::git — else the PR its checkout's branch
/// has, while the window shows it.
fn pull_request_url(engine: &Engine, key: &str) -> String {
    store::with(engine, |s| {
        s.thread_row(key)
            .and_then(|r| r.get("linkedPullRequest"))
            .and_then(|pr| pr.get("url"))
            .and_then(Json::as_str)
            .unwrap_or_default()
            .to_owned()
    })
}

/// TODO(port): NavigationController::Route::projectKey — the settings route
/// has no project yet, so the projects page opens on its first.
fn open_project_settings(engine: &Engine, key: &str) {
    if thread(engine, key).is_none() {
        return;
    }
    open_route(engine, Route::Settings(PROJECT_SETTINGS.into()));
}

/// The thread's worktree, else its project's folder.
fn workspace_path(engine: &Engine, key: &str) -> String {
    let worktree = row_text(engine, key, "worktreePath");
    if !worktree.is_empty() {
        return worktree;
    }
    thread(engine, key).map_or_else(String::new, |t| project_root(engine, &t))
}

/// A copy of the thread up to its latest finished run, opened once the MC
/// has it.
fn fork(engine: &Engine, key: &str) {
    let Some(thread) = thread(engine, key) else {
        return;
    };
    let target = hal_c2_mc::new_uuid();
    let opened = format!("{}:{target}", thread.environment_id);
    command(
        engine,
        key,
        json!({
            "type": "thread.fork",
            "sourceThreadId": thread.id,
            "targetThreadId": target,
            "sourcePoint": {"type": "latest_stable"},
            "createdBy": "user",
            "creationSource": "web",
        }),
        "Failed to fork thread",
        Some(Box::new(move |engine: &Engine| {
            open_route(engine, Route::Thread(opened));
        })),
    );
}

/// The machines that could take the thread, as a second menu where the
/// first was.
fn choose_destination(engine: &Engine, key: &str, x: f64, y: f64) {
    let (Some(thread), Some(mc)) = (thread(engine, key), controller::mc(engine)) else {
        return;
    };
    let key = key.to_owned();
    mc.call(
        &thread.environment_id,
        "hal-c2.moveDestinations",
        json!({"threadId": thread.id}),
        Box::new(move |engine, result| {
            let destinations = match result {
                Ok(Json::Array(destinations)) => destinations,
                Ok(_) => Vec::new(),
                Err(error) => {
                    toast_error(engine, "Failed to move thread", &error.message);
                    return;
                }
            };
            let text = |d: &Json, field: &str| d[field].as_str().unwrap_or_default().to_owned();
            let offered: Vec<String> = destinations.iter().map(|d| text(d, "machine")).collect();
            let mut labels = HashMap::new();
            let items: Vec<Item> = destinations
                .iter()
                .map(|d| {
                    let id = text(d, "environmentId");
                    let machine = text(d, "machine");
                    let name = machine_name(&machine, &id, &offered);
                    let online = d["online"] == Json::Bool(true);
                    let mut item = item(
                        &format!("machine:{id}"),
                        if online {
                            name
                        } else {
                            format!("{name} (offline)")
                        },
                        "monitor",
                    );
                    item.enabled = online;
                    labels.insert(id, machine);
                    item
                })
                .collect();
            if items.is_empty() {
                show(
                    engine,
                    "info",
                    "No other machine can take this thread",
                    "",
                    DEFAULT_TIMEOUT_MS,
                );
                return;
            }
            open_menu(engine, x, y, items, move |engine, chosen| {
                let id = chosen.strip_prefix("machine:").unwrap_or(chosen).to_owned();
                let label = labels.get(&id).cloned().unwrap_or_else(|| id.clone());
                let machine = Machine { id, label };
                let key = key.clone();
                controller::with::<ThreadMenu, _>(engine, |m, e| {
                    m.start_move(
                        e,
                        &key,
                        machine,
                        Asking {
                            x,
                            y,
                            palette: false,
                        },
                    );
                });
            });
        }),
    );
}

/// `hal-c2.moveThread` answers moved, or asks to confirm what stays behind,
/// or which project to move into; each question is asked and the move sent
/// again.
fn move_thread(
    engine: &Engine,
    key: &str,
    machine: Machine,
    project_id: String,
    confirmed: bool,
    asking: Asking,
) {
    let (Some(thread), Some(mc)) = (thread(engine, key), controller::mc(engine)) else {
        return;
    };
    let mut input = json!({"threadId": thread.id, "machine": machine.id});
    if !project_id.is_empty() {
        input["projectId"] = json!(project_id);
    }
    if confirmed {
        input["confirmed"] = json!(true);
    }
    let progress = show(
        engine,
        "loading",
        &format!("Moving \"{}\" to {}…", thread.title, machine.label),
        "",
        0,
    );
    let key = key.to_owned();
    let title = thread.title.clone();
    mc.call(
        &thread.environment_id,
        "hal-c2.moveThread",
        input,
        Box::new(move |engine, result| {
            dismiss(engine, &progress);
            let answer = match result {
                Ok(answer) => answer,
                Err(error) => {
                    toast_error(engine, "Failed to move thread", &error.message);
                    return;
                }
            };
            let text = |v: &Json, field: &str| v[field].as_str().unwrap_or_default().to_owned();
            match answer["status"].as_str().unwrap_or_default() {
                "confirm" => {
                    let notes: Vec<String> = answer["notes"]
                        .as_array()
                        .map(|notes| {
                            notes
                                .iter()
                                .map(|n| {
                                    if n.is_object() {
                                        text(n, "message")
                                    } else {
                                        n.as_str().unwrap_or_default().to_owned()
                                    }
                                })
                                .filter(|n| !n.is_empty())
                                .collect()
                        })
                        .unwrap_or_default();
                    let description = if notes.is_empty() {
                        text(&answer, "message")
                    } else {
                        notes.join("\n")
                    };
                    let again = machine.clone();
                    confirm(
                        engine,
                        &format!("Move \"{title}\" to {}?", machine.label),
                        &description,
                        "Move",
                        false,
                        Rc::new(move |engine: &Engine| {
                            move_thread(
                                engine,
                                &key,
                                again.clone(),
                                project_id.clone(),
                                true,
                                asking,
                            );
                        }),
                        None,
                    );
                }
                "choose_project" => {
                    let mut items = Vec::new();
                    let mut choices = Vec::new();
                    for project in answer["projects"].as_array().into_iter().flatten() {
                        let id = text(project, "id");
                        let title = text(project, "title");
                        items.push(item(&format!("project:{id}"), title.clone(), "folder"));
                        let (key, machine, chosen) = (key.clone(), machine.clone(), id.clone());
                        let mut choice = Choice::new(&id, &title, move |engine| {
                            move_thread(
                                engine,
                                &key,
                                machine.clone(),
                                chosen.clone(),
                                confirmed,
                                asking,
                            );
                        });
                        choice.description = text(project, "workspaceRoot");
                        choices.push(choice);
                    }
                    controller::with::<ThreadMenu, _>(engine, |m, _| {
                        *m.project_choices.borrow_mut() = choices;
                    });
                    if asking.palette {
                        Commands::of(engine).run(engine, MOVE_PROJECT);
                        return;
                    }
                    open_menu(engine, asking.x, asking.y, items, move |engine, id| {
                        let project = id.strip_prefix("project:").unwrap_or(id).to_owned();
                        move_thread(engine, &key, machine.clone(), project, confirmed, asking);
                    });
                }
                "moved" => {
                    let message = text(&answer, "message");
                    let title = if message.is_empty() {
                        format!("Moved to {}", machine.label)
                    } else {
                        message
                    };
                    show(engine, "success", &title, "", DEFAULT_TIMEOUT_MS);
                    // The user who moved the thread is shown it where it lives now.
                    let environment_id = text(&answer, "environmentId");
                    if !environment_id.is_empty() {
                        let id = key.split_once(':').map_or(key.as_str(), |(_, id)| id);
                        open_route(engine, Route::Thread(format!("{environment_id}:{id}")));
                    }
                }
                _ => {}
            }
        }),
    );
}

/// A draft of the thread's project on its branch.
fn new_thread_on_branch(engine: &Engine, key: &str) {
    let Some(thread) = thread(engine, key) else {
        return;
    };
    if thread.branch.is_none() {
        return;
    }
    // TODO(port): WorkspaceController::setCheckout — the draft starts on the
    // thread's branch (its worktree when it has one); here it starts on the
    // project's default checkout.
    drafts::start(engine, &thread.environment_id, &thread.project_id);
}

/// What the palette shows of the route thread's commands.
fn present(engine: &Engine) {
    let commands = Commands::of(engine);
    let key = route_thread(engine);
    let thread = (!key.is_empty()).then(|| thread(engine, &key)).flatten();
    let url = if thread.is_some() {
        pull_request_url(engine, &key)
    } else {
        String::new()
    };
    commands.set_title(
        engine,
        COPY_REFERENCE,
        if url.is_empty() {
            "Copy thread ID"
        } else {
            "Copy PR link"
        },
    );
    let description = match (&thread, url.is_empty()) {
        (Some(thread), true) => thread.id.clone(),
        _ => url,
    };
    commands.set_description(engine, COPY_REFERENCE, &description);
    commands.set_listed(engine, COPY_REFERENCE, thread.is_some());
    let project = thread.as_ref().and_then(|t| {
        store::with(engine, |s| {
            s.project(&format!("{}:{}", t.environment_id, t.project_id))
        })
    });
    commands.set_description(
        engine,
        PROJECT_SETTINGS_COMMAND,
        project.as_ref().map_or("", |p| p.title.as_str()),
    );
    commands.set_listed(engine, PROJECT_SETTINGS_COMMAND, project.is_some());
    let environments = store::with(engine, |s| s.environments());
    commands.set_description(
        engine,
        MOVE,
        thread.as_ref().map_or("", |t| t.title.as_str()),
    );
    commands.set_listed(
        engine,
        MOVE,
        thread
            .as_ref()
            .is_some_and(|t| environments.iter().any(|e| *e != t.environment_id)),
    );
}
