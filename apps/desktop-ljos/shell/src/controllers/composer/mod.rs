//! `composer`, desktop-qt's ComposerController: the composer on the thread
//! or new-thread draft the window shows (the route), against the MC. The
//! draft itself (text, caret, model, options, modes, images and files,
//! terminal excerpts, review notes, quoted replies), what the picker offers,
//! the @ $ / suggestions, sending, follow-ups while a turn runs, stop, the
//! thread's pending approvals and questions, its proposed plan and queue,
//! the stash and the prompt history.
//!
//! Each thread keeps its draft in [`kept`], saved on this machine
//! ([`set_store_path`]); a new thread's text is the drafts'
//! (`controllers::drafts`). The catalogue is the `providers` of the route
//! environment's config (`workspace::environment_config`). A new thread's
//! first send launches it (`orchestration.launchThread`) in the checkout
//! the workspace picked, or on another machine when the MC places it there
//! (`hal-c2.placeThread`); a background send leaves the draft for another
//! prompt. A send is kept with the drafts until the MC answers it; one a
//! quit or a drop cut off comes back to its draft (`reconcile_unsent`).
//!
//! Publishes `composer` (ShellComposerState in
//! packages/contracts/src/shell.ts; null with no thread or draft open),
//! `modelPicker` (ShellModelPickerState), `composerStash` ({entries [{id,
//! snippet, createdAt}], open, shortcut}) and `turn`, the route thread's
//! requests: {threadKey, kind: thread | draft, running, sending (a draft's),
//! approvals [{requestId, title, appName, detail, options [{decision, label,
//! warning}], canRespond, responding, problem}], questions [{requestId,
//! questions [{id, ..., attachments}], canRespond, responding, problem}],
//! plan {id, title, markdown} | null, queue, waiting, queueHeld,
//! queueResuming}: the MC keeps a held queue until it is resumed.
//!
//! Actions: composer.text.set {target, text, cursor, edit},
//! composer.suggest.select {id}, composer.suggest.dismiss,
//! composer.history.step {direction}, composer.model.select {instanceId,
//! model}, composer.model.multiple.toggle, composer.model.favorite.toggle,
//! composer.usageLimits.dismiss, composer.option.set {id, value},
//! composer.runtimeMode.set {mode}, composer.interactionMode.set {mode},
//! composer.submit {text, intent, edit}, composer.interrupt,
//! composer.attach {files, folders}, composer.attachment.remove {id},
//! composer.attachment.retry {id}, composer.question.attach {requestId,
//! questionId, files}, composer.question.attachment.remove {id},
//! composer.terminalContext.add / .remove, composer.reviewComment.add /
//! .remove, composer.citation.add / .comment / .remove,
//! composer.approval.respond {requestId, decision}, composer.question.answer
//! {requestId, answers}, composer.question.dismiss {requestId},
//! composer.plan.implement, composer.queue.remove {runId},
//! composer.queue.steer {runId?}, composer.queue.edit {runId?},
//! composer.queue.edit.cancel, composer.queue.resume (a held queue),
//! composer.stash, composer.stash.restore {id},
//! composer.stash.delete {id}, composer.stash.menu {open?}.

pub mod kept;
pub mod text;

mod attachments;
mod requests;
mod send;
mod state;

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::rc::Rc;

use ljos::prelude::{Engine, ObjectId};
use serde_json::json;

use kept::{Attachment, Draft};
pub use kept::{adopt, attachments, attachments_pending, draft, draft_preview, terminal_contexts};

use crate::bridge::Bridge;
use crate::composer_model::{self as model, Instance};
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::drafts;
use crate::controllers::keybindings::Keymap;
use crate::controllers::navigation::{self, Route};
use crate::controllers::settings::Settings;
use crate::controllers::sidebar::{self, Sidebar};
use crate::controllers::threads;
use crate::controllers::toasts::{DEFAULT_TIMEOUT_MS, Toasts};
use crate::controllers::workspace;
use crate::json::Json;
use crate::mc::{Mc, McError, Reply};
use crate::store;
use crate::thread_view::summary::{Obj, as_object, text as field};
use crate::thread_view::timeline::{Out, Timeline};
use crate::thread_view::timeline_model::TimelineModel;

/// The @ menu's search of the route's checkout, and what it found.
#[derive(Default)]
struct PathSearch {
    target: String,
    query: String,
    done: bool,
    entries: Vec<(String, bool)>,
    request: u64,
}

/// The sent prompt the history last put in the composer.
struct Recall {
    target: String,
    entry_id: String,
    recalled: String,
}

pub struct Composer {
    bridge: Bridge,
    mc: Rc<dyn Mc>,
    me: Me<Composer>,
    active: bool,
    /// The route's thread, or its draft's id.
    thread: String,
    draft_id: String,
    /// The route thread's timeline, while the threads have one for it.
    timeline: Option<ObjectId>,
    /// The timelines this one observes: an observer cannot be removed, so
    /// each is added once and heard only while it is the route's.
    observed: HashSet<ObjectId>,
    /// Requests answered and waiting on the MC; requests the MC said are
    /// gone.
    responding: HashSet<String>,
    closed: HashSet<String>,
    /// Drafts whose first send is on its way.
    launching: HashSet<String>,
    /// Each image's thumbnail by attachment id; empty while it is made.
    previews: HashMap<String, String>,
    /// The thumbnails being made and the files being read on the compute
    /// pool, by attachment id, each with the generation that asked for it:
    /// only that one's answer counts.
    making: HashMap<String, u64>,
    reading: HashMap<String, u64>,
    /// The newest generation handed to the pool.
    generation: u64,
    stash_open: bool,
    catalogue: Vec<Instance>,
    paths: PathSearch,
    recall: Option<Recall>,
    /// What "/usage-limits" showed, by target.
    usage_limits: HashMap<String, Json>,
    /// This window's "Not connected: queue not resumed" toast, while it may
    /// still show.
    not_connected_toast: String,
}

/// Runs `f` on the composer once no controller is running: what an MC
/// reply, a hook or a timer calls, which may come while the composer itself
/// set it off (a route it published, a draft it promoted).
fn later(me: &Me<Composer>, engine: &Engine, f: impl FnOnce(&mut Composer, &Engine) + 'static) {
    let me = me.clone();
    Bridge::of(engine).defer(engine, move |engine| me.run(engine, f));
}

/// An MC reply handed to the composer, deferred as [`later`].
fn back(
    me: &Me<Composer>,
    f: impl FnOnce(&mut Composer, &Engine, Result<Json, McError>) + 'static,
) -> Reply {
    let me = me.clone();
    Box::new(move |engine, result| later(&me, engine, move |c, e| f(c, e, result)))
}

/// A hook that runs `f` on the composer, deferred as [`later`].
fn hook(me: &Me<Composer>, f: fn(&mut Composer, &Engine)) -> impl Fn(&Engine) + 'static {
    let me = me.clone();
    move |engine| later(&me, engine, f)
}

/// A drop took the answer: the call never reached the MC, or its reply
/// never came back.
fn unanswered(error: &McError) -> bool {
    error.message == "disconnected"
}

fn uuid() -> String {
    hal_c2_mc::new_uuid()
}

/// The text of a payload field.
fn string(payload: &Json, key: &str) -> String {
    payload
        .get(key)
        .and_then(Json::as_str)
        .unwrap_or_default()
        .to_owned()
}

fn now_iso(engine: &Engine) -> String {
    let ms = sidebar::now_ms(engine);
    chrono::DateTime::from_timestamp_millis(ms)
        .map(|at| crate::sidebar_model::format_iso(&at))
        .unwrap_or_default()
}

fn toast(engine: &Engine, kind: &str, title: &str, description: &str) {
    controller::with::<Toasts, _>(engine, |t, e| {
        t.show(e, kind, title, description, None, DEFAULT_TIMEOUT_MS);
    });
}

/// An error toast; an empty reason reads "An error occurred.".
fn toast_error(engine: &Engine, title: &str, description: &str) {
    controller::with::<Toasts, _>(engine, |t, e| {
        t.error(e, title, description);
    });
}

fn setting(engine: &Engine, key: &str) -> Json {
    Settings::of(engine)
        .setting(engine, key)
        .unwrap_or(Json::Null)
}

fn thread_of(engine: &Engine, key: &str) -> Option<crate::sidebar_model::Thread> {
    store::with(engine, |s| s.thread(key))
}

impl Controller for Composer {
    fn new(init: Init<'_, Self>) -> Self {
        Composer {
            bridge: init.bridge,
            mc: init.mc,
            me: init.me,
            active: false,
            thread: String::new(),
            draft_id: String::new(),
            timeline: None,
            observed: HashSet::new(),
            responding: HashSet::new(),
            closed: HashSet::new(),
            launching: HashSet::new(),
            previews: HashMap::new(),
            making: HashMap::new(),
            reading: HashMap::new(),
            generation: 0,
            stash_open: false,
            catalogue: Vec::new(),
            paths: PathSearch::default(),
            recall: None,
            usage_limits: HashMap::new(),
            not_connected_toast: String::new(),
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let follow = hook(&self.me, Composer::follow);
        self.bridge.watch(engine, "route", move |e, _| follow(e));
        // The thread's timeline exists once the store has followed it.
        threads::on_active_changed(engine, hook(&self.me, Composer::follow));
        // A draft opened, renewed or promoted.
        drafts::on_changed(engine, hook(&self.me, Composer::publish));
        // The row says whether a turn runs, which decides follow-ups and
        // the plan.
        store::on_changed(
            engine,
            hook(&self.me, |c, e| {
                c.carry_drafts(e);
                c.reconcile_unsent(e);
                c.publish(e);
            }),
        );
        // The route environment's providers are the picker's catalogue.
        workspace::on_config_changed(
            engine,
            hook(&self.me, |c, e| {
                c.refresh_catalogue(e);
                c.publish(e);
            }),
        );
        let settings = Settings::of(engine);
        settings.on_settings_changed(hook(&self.me, Composer::publish));
        settings.on_device_changed(hook(&self.me, Composer::publish));
        Keymap::of(engine).on_bindings_changed(hook(&self.me, Composer::publish));
        self.refresh_catalogue(engine);
        self.follow(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !self.active || !action.starts_with("composer.") {
            return false;
        }
        self.handle_action(engine, action, payload)
    }
}

impl Composer {
    /// The thread or draft the window's composer writes to; empty with
    /// neither open (or the thread not listed).
    fn target(&self, engine: &Engine) -> String {
        if !self.draft_id.is_empty() {
            return if drafts::draft(engine, &self.draft_id).is_some() {
                self.draft_id.clone()
            } else {
                String::new()
            };
        }
        if thread_of(engine, &self.thread).is_some() {
            self.thread.clone()
        } else {
            String::new()
        }
    }

    /// Follows the route's thread and its stream.
    fn follow(&mut self, engine: &Engine) {
        let (thread, draft_id) = match navigation::shown(engine) {
            Route::Thread(key) => (key, String::new()),
            Route::Draft(id) => (String::new(), id),
            _ => (String::new(), String::new()),
        };
        self.thread = if draft_id.is_empty() {
            thread.clone()
        } else {
            draft_id.clone()
        };
        self.draft_id = draft_id;
        // Leaving the thread leaves its edit, as cancelling would.
        let editing = kept::read(engine, |d| d.queued_edit.as_ref().map(|e| e.thread.clone()));
        if editing.is_some_and(|t| t != self.thread) {
            self.end_queued_edit(engine, false);
        }
        let timeline = if thread.is_empty() {
            None
        } else {
            threads::timeline_of(engine, &thread)
        };
        if timeline != self.timeline {
            self.timeline = timeline;
            if let Some(obj) = timeline
                && self.observed.insert(obj)
            {
                let me = self.me.clone();
                TimelineModel::observe(engine, obj, move |engine, out| {
                    let f: fn(&mut Composer, &Engine) = match out {
                        Out::TurnChanged => Composer::publish,
                        // A thread's messages are known once its stream is live.
                        Out::StatusChanged => Composer::reconcile_unsent,
                        _ => return,
                    };
                    later(&me, engine, move |c, e| {
                        if c.timeline == Some(obj) {
                            f(c, e);
                        }
                    });
                });
            }
        }
        self.reconcile_unsent(engine);
        self.publish(engine);
    }

    /// Reads the route thread's timeline; the default without one. `f` must
    /// not reach the engine.
    fn read_timeline<R: Default>(&self, engine: &Engine, f: impl FnOnce(&Timeline) -> R) -> R {
        self.timeline
            .and_then(|obj| TimelineModel::read(engine, obj, f))
            .unwrap_or_default()
    }

    fn publish(&mut self, engine: &Engine) {
        if !self.active {
            return;
        }
        let turn = self.turn_state(engine);
        if kept::read(engine, |d| d.queued_edit.is_some()) {
            self.recover_queued_edit(engine, &turn);
            // Ending the edit published everything already.
            if kept::read(engine, |d| d.queued_edit.is_none()) {
                return;
            }
        }
        let composer = self.composer_state(engine, &turn);
        let picker = self.picker_state(engine);
        let stash = self.stash_state(engine);
        self.bridge.publish(engine, "turn", turn);
        self.bridge.publish(engine, "composer", composer);
        self.bridge.publish(engine, "modelPicker", picker);
        self.bridge.publish(engine, "composerStash", stash);
        // The sidebar lists the draft by what it holds.
        if !self.draft_id.is_empty() {
            let id = self.draft_id.clone();
            Bridge::of(engine).defer(engine, move |engine| {
                controller::with::<Sidebar, _>(engine, |s, e| s.draft_edited(e, &id));
            });
        }
    }

    /// The text of `target` becomes `text` with the caret at `cursor`
    /// (UTF-16 units); `edit` is the brick's edit it answers, Null for the
    /// shell's own change.
    fn set_text(&mut self, engine: &Engine, target: &str, text: &str, cursor: i64, edit: &Json) {
        let changed = text != kept::draft(engine, target);
        let cursor = cursor.clamp(0, model::utf16_len(text) as i64);
        let is_draft = drafts::draft(engine, target).is_some();
        kept::edit_draft(engine, target, |kept| {
            if !edit.is_null() {
                kept.edit = edit.clone();
            }
            if changed || cursor != kept.cursor {
                kept.dismissed = false;
            }
            kept.cursor = cursor;
            if changed && !is_draft {
                kept.text = text.to_owned();
            }
        });
        if changed {
            if is_draft {
                // A new thread's text is kept with its draft.
                drafts::set_text(engine, target, text);
            } else {
                kept::save(engine);
            }
        }
        self.search_paths(engine, target);
        self.publish(engine);
    }

    /// The text cleared or replaced by the shell, the caret at its end.
    fn set_text_end(&mut self, engine: &Engine, target: &str, text: &str) {
        let end = model::utf16_len(text) as i64;
        self.set_text(engine, target, text, end, &Json::Null);
    }

    /// A thread's own model; for a draft the project's default: this
    /// device's project override, the project's, then the default for new
    /// threads, then the model last sent with while its provider can run
    /// it. Empty lets the MC choose.
    fn base_selection(&self, engine: &Engine, key: &str) -> Obj {
        if let Some(thread) = thread_of(engine, key) {
            return thread.model_selection;
        }
        let Some(draft) = drafts::draft(engine, key) else {
            return Obj::new();
        };
        let settings = Settings::of(engine);
        let value = |path: &str| {
            settings
                .value(path)
                .map(|v| as_object(&v).clone())
                .unwrap_or_default()
        };
        let mut selection = value(&format!(
            "projectSettingsOverrides.{}.defaultModelSelection",
            draft.project_id
        ));
        if selection.is_empty() {
            selection = store::with(engine, |s| {
                s.project_row(&draft.environment_id, &draft.project_id)
                    .map(|row| {
                        as_object(row.get("defaultModelSelection").unwrap_or(&Json::Null)).clone()
                    })
                    .unwrap_or_default()
            });
        }
        if selection.is_empty() {
            selection = as_object(&setting(engine, "defaultModelSelection")).clone();
        }
        if selection.is_empty() {
            let last = kept::read(engine, |d| {
                d.last_models
                    .get(&d.last_instance)
                    .cloned()
                    .unwrap_or_default()
            });
            if let Some(instance) = self.instance_of(&last)
                && instance.ready()
                && !model::find_model(instance, field(&last, "model")).is_empty()
            {
                selection = last;
            }
        }
        selection
    }

    fn instance_of(&self, selection: &Obj) -> Option<&Instance> {
        model::find(&self.catalogue, field(selection, "instanceId"))
    }

    /// The model `target` sends with: its own choice, else its base; the
    /// first ready instance's default without one.
    fn selection(&self, engine: &Engine, target: &str) -> Obj {
        let mut chosen = kept::read(engine, |d| {
            d.drafts.get(target).and_then(|k| k.model_selection.clone())
        })
        .unwrap_or_else(|| self.base_selection(engine, target));
        if field(&chosen, "instanceId").is_empty() {
            let Some(ready) = self.catalogue.iter().find(|i| i.ready()) else {
                return Obj::new();
            };
            return json!({"instanceId": ready.instance_id, "model": model::default_model(ready)})
                .as_object()
                .cloned()
                .unwrap_or_default();
        }
        if field(&chosen, "model").is_empty()
            && let Some(instance) = self.instance_of(&chosen)
        {
            chosen.insert("model".into(), json!(model::default_model(instance)));
        }
        chosen
    }

    fn plan_mode_on(&self, engine: &Engine, instance: Option<&Instance>) -> bool {
        instance.is_some_and(|i| i.show_interaction_mode_toggle)
            && setting(engine, "planModeEnabled")
                .as_bool()
                .unwrap_or(false)
    }

    fn plan_on_for(&self, engine: &Engine, target: &str) -> bool {
        let selection = self.selection(engine, target);
        self.plan_mode_on(engine, self.instance_of(&selection))
    }

    fn runtime_mode_of(&self, engine: &Engine, target: &str) -> String {
        let own = kept::read(engine, |d| {
            d.drafts
                .get(target)
                .map(|k| k.runtime_mode.clone())
                .unwrap_or_default()
        });
        if !own.is_empty() {
            return own;
        }
        if let Some(thread) = thread_of(engine, target)
            && !thread.runtime_mode.is_empty()
        {
            return thread.runtime_mode;
        }
        // A new thread: its project's default permissions, else the default
        // for new threads (Settings, Project defaults).
        if let Some(draft) = drafts::draft(engine, target) {
            let settings = Settings::of(engine);
            for path in [
                format!(
                    "projectSettingsOverrides.{}.defaultRuntimeMode",
                    draft.project_id
                ),
                "defaultRuntimeMode".to_owned(),
            ] {
                if let Some(mode) = settings.value(&path).as_ref().and_then(Json::as_str)
                    && !mode.is_empty()
                {
                    return mode.to_owned();
                }
            }
        }
        "full-access".into()
    }

    /// The mode a send uses: plan only while plan mode is on.
    fn interaction_mode_of(&self, engine: &Engine, target: &str) -> String {
        if !self.plan_on_for(engine, target) {
            return "default".into();
        }
        let own = kept::read(engine, |d| {
            d.drafts
                .get(target)
                .map(|k| k.interaction_mode.clone())
                .unwrap_or_default()
        });
        if !own.is_empty() {
            return own;
        }
        match thread_of(engine, target) {
            Some(thread) if !thread.interaction_mode.is_empty() => thread.interaction_mode,
            _ => "default".into(),
        }
    }

    fn refresh_catalogue(&mut self, engine: &Engine) {
        let config = workspace::environment_config(engine);
        let providers = config
            .get("providers")
            .and_then(Json::as_array)
            .cloned()
            .unwrap_or_default();
        self.catalogue = model::instances(&providers);
    }

    /// A thread that moved to another machine has a new key: what was
    /// written for it, and the model and modes chosen, follow it there.
    fn carry_drafts(&mut self, engine: &Engine) {
        let keys: Vec<String> = kept::read(engine, |d| d.drafts.keys().cloned().collect());
        let moved: Vec<(String, String)> = store::with(engine, |s| {
            keys.iter()
                .filter_map(|key| {
                    let located = s.located(key);
                    (located != *key).then(|| (key.clone(), located))
                })
                .collect()
        });
        if moved.is_empty() {
            return;
        }
        kept::write(engine, |d| {
            for (from, to) in moved {
                let Some(mut carried) = d.drafts.remove(&from) else {
                    continue;
                };
                // The brick showing the thread there has made no edit yet.
                carried.edit = Json::Null;
                if !d.drafts.get(&to).is_some_and(Draft::holds_anything) {
                    d.drafts.insert(to, carried);
                }
            }
        });
        kept::save(engine);
    }

    /// The environment a thread's or a new thread's files go to.
    fn environment_of(&self, engine: &Engine, target: &str) -> String {
        if let Some(thread) = thread_of(engine, target) {
            return thread.environment_id;
        }
        if drafts::draft(engine, target).is_some() {
            return workspace::launch(engine, target).environment_id;
        }
        String::new()
    }

    /// Adds `text` after the route's draft, a space apart from what is
    /// there; false with no thread or draft open.
    pub fn insert_at_end(&mut self, engine: &Engine, text: &str) -> bool {
        let target = self.target(engine);
        if target.is_empty() {
            return false;
        }
        let mut next = kept::draft(engine, &target);
        if next.chars().last().is_some_and(|c| !c.is_whitespace()) {
            next.push(' ');
        }
        next.push_str(text);
        self.set_text_end(engine, &target, &next);
        true
    }

    /// The model the window's thread or draft will send with:
    /// {instanceId, model}, empty with none ready.
    pub fn current_selection(&self, engine: &Engine) -> Obj {
        self.selection(engine, &self.target(engine))
    }
}

/// Where the threads' drafts are kept; loads them from there and shows them
/// once the composer is active.
pub fn set_store_path(engine: &Engine, path: Option<PathBuf>) {
    kept::load(engine, path);
    if let Some(composer) = controller::controller::<Composer>(engine) {
        let me = Me::clone(&composer.borrow().me);
        later(&me, engine, Composer::publish);
    }
}

/// Adds `text` after the open draft (the Files tab's Add to chat); false
/// with no thread or draft open, or while the composer is busy.
pub fn insert_at_end(engine: &Engine, text: &str) -> bool {
    controller::with::<Composer, _>(engine, |c, e| c.insert_at_end(e, text)).unwrap_or(false)
}

/// An image (a snapshot) joins `target`'s draft: a thread key or a draft
/// id. `source` rides with it to the MC when set (ChatImageAttachment.source).
pub fn attach_image(
    engine: &Engine,
    target: &str,
    name: &str,
    mime_type: &str,
    bytes: &[u8],
    source: Obj,
) {
    attachments::attach_image(engine, target, name, mime_type, bytes, source);
    if let Some(composer) = controller::controller::<Composer>(engine) {
        let me = Me::clone(&composer.borrow().me);
        later(&me, engine, Composer::publish);
    }
}

/// A draft's (or a question's) attachment as this machine holds it, for a
/// viewer: {id, name, mimeType, url (an image's data URL), text (a file's,
/// when it reads as text)}; None when it is gone.
pub fn attachment_preview(engine: &Engine, id: &str) -> Option<Json> {
    attachments::preview(engine, id)
}

/// The model the window's thread or draft will send with; empty while the
/// composer is busy or there is none.
pub fn current_selection(engine: &Engine) -> Obj {
    controller::with::<Composer, _>(engine, |c, e| c.current_selection(e)).unwrap_or_default()
}

/// Every window's composer publishes again, once it is free: what one window
/// changed in what they share ([`kept`]) the others show too. The composer
/// running now is skipped: it publishes itself.
fn publish_everywhere(engine: &Engine) {
    controller::each_window(engine, |engine| {
        let Some(composer) = controller::controller::<Composer>(engine) else {
            return;
        };
        let Ok(me) = composer.try_borrow().map(|c| c.me.clone()) else {
            return;
        };
        later(&me, engine, Composer::publish);
    });
}

/// The kept attachment `id` of any draft or question's answer.
fn find_attachment(engine: &Engine, id: &str) -> Option<Attachment> {
    kept::find_attachment(engine, id)
}
