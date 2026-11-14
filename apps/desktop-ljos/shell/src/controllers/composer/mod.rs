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
mod images;
mod page;
mod queued;
mod requests;
mod send;
mod state;

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::rc::Rc;
use std::time::Instant;

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
use crate::controllers::space;
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
    environment_id: String,
    cwd: String,
    done: bool,
    failed: bool,
    entries: Vec<(String, bool)>,
    request: u64,
}

/// The sent prompt the history last put in the composer.
struct Recall {
    target: String,
    entry_id: String,
    recalled: String,
}

/// Which of a thread's modes a pick sets.
#[derive(Clone, Copy)]
enum ModeKind {
    Runtime,
    Interaction,
}

impl ModeKind {
    fn of(self, draft: &kept::Draft) -> &String {
        match self {
            ModeKind::Runtime => &draft.runtime_mode,
            ModeKind::Interaction => &draft.interaction_mode,
        }
    }

    fn of_mut(self, draft: &mut kept::Draft) -> &mut String {
        match self {
            ModeKind::Runtime => &mut draft.runtime_mode,
            ModeKind::Interaction => &mut draft.interaction_mode,
        }
    }
}

/// A mode change sent to the MC: once `accepted`, the version of the
/// rows (`mc`, `epoch`, `rev`) that holds it; no epoch from an MC that names
/// none.
#[derive(Default)]
struct SettingMode {
    mode: String,
    accepted: bool,
    mc: String,
    epoch: String,
    rev: i64,
}

type AfterOwn = Box<dyn FnOnce(&mut Composer, &Engine)>;

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
    /// Whether the target held files when last published.
    held_files: bool,
    catalogue: Vec<Instance>,
    /// How many catalogues have been announced.
    catalogues: u64,
    /// Each environment, instance and folder asked for (`ask_folder`).
    folders_asked: HashMap<String, FolderAsk>,
    paths: PathSearch,
    recall: Option<Recall>,
    /// What "/usage-limits" showed, by target.
    usage_limits: HashMap<String, Json>,
    /// The access changes on their way to the MC, by draft target.
    setting_mode: HashMap<String, SettingMode>,
    setting_interaction: HashMap<String, SettingMode>,
    /// This client's own mode changes to each thread that may still move
    /// its selectionRevision, and the sends waiting for their answers
    /// (`dispatch_all`).
    own: HashMap<String, Vec<kept::OwnChange>>,
    after_own: HashMap<String, Vec<AfterOwn>>,
    /// This window's "Not connected: queue not resumed" toast, while it may
    /// still show.
    not_connected_toast: String,
    /// The threads whose queue action the MC has not answered.
    queue_busy: HashSet<String>,
    /// The Space page whose prompt this is, while no thread or draft is
    /// open; the project its ask runs in (the MC's), whether it was asked,
    /// and whether the page's agent works. The projects picked, by page key.
    page_id: String,
    page_project: String,
    page_project_asked: bool,
    page_running: bool,
    page_projects: HashMap<String, String>,
    /// The Space whose images' prompt this is, with no page open either.
    images_space: String,
}

/// Runs `f` on the composer once no controller is running: what an MC
/// reply, a hook or a timer calls, which may come while the composer itself
/// set it off (a route it published, a draft it promoted).
fn later(me: &Me<Composer>, engine: &Engine, f: impl FnOnce(&mut Composer, &Engine) + 'static) {
    let me = me.clone();
    Bridge::of(engine).defer(engine, move |engine| me.run(engine, f));
}

/// An MC reply handed to the composer, deferred as [`later`].
/// A folder's read (`ask_folder`): whether it is still out, whether the MC
/// kept what it read, the catalogue current when it answered, and until when
/// the answer stands.
struct FolderAsk {
    reading: bool,
    kept: bool,
    answered_at: u64,
    stands: Instant,
}

fn back(
    me: &Me<Composer>,
    f: impl FnOnce(&mut Composer, &Engine, Result<Json, McError>) + 'static,
) -> Reply {
    let me = me.clone();
    Box::new(move |engine, result| later(&me, engine, move |c, e| f(c, e, result)))
}

/// The project's own default model: the device's override, else the
/// project's. Empty for none.
fn project_selection(engine: &Engine, environment_id: &str, project_id: &str) -> Obj {
    if project_id.is_empty() {
        return Obj::new();
    }
    let own = Settings::of(engine)
        .value(&format!(
            "projectSettingsOverrides.{project_id}.defaultModelSelection"
        ))
        .map(|v| as_object(&v).clone())
        .unwrap_or_default();
    if !own.is_empty() {
        return own;
    }
    store::with(engine, |s| {
        s.project_row(environment_id, project_id)
            .map(|row| as_object(row.get("defaultModelSelection").unwrap_or(&Json::Null)).clone())
            .unwrap_or_default()
    })
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
            held_files: false,
            catalogue: Vec::new(),
            catalogues: 0,
            folders_asked: HashMap::new(),
            paths: PathSearch::default(),
            recall: None,
            usage_limits: HashMap::new(),
            setting_mode: HashMap::new(),
            setting_interaction: HashMap::new(),
            own: HashMap::new(),
            after_own: HashMap::new(),
            not_connected_toast: String::new(),
            queue_busy: HashSet::new(),
            page_id: String::new(),
            page_project: String::new(),
            page_project_asked: false,
            page_running: false,
            page_projects: HashMap::new(),
            images_space: String::new(),
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
        // A new thread carries the model and mode it was started from.
        drafts::on_started(engine, {
            let me = self.me.clone();
            move |engine, id, from| {
                let (id, from) = (id.to_owned(), from.to_owned());
                later(&me, engine, move |c, e| c.carry_into(e, &id, &from));
            }
        });
        // The row says whether a turn runs, which decides follow-ups and
        // the plan.
        store::on_changed(
            engine,
            hook(&self.me, |c, e| {
                c.carry_drafts(e);
                c.forget_taken_picks(e);
                c.reconcile_unsent(e);
                c.settle_modes(e);
                c.refresh_path_search(e);
                c.publish(e);
            }),
        );
        // The route's checkout arrived or moved, so an @ word can now be
        // searched.
        workspace::on_place_changed(
            engine,
            hook(&self.me, |c, e| {
                c.refresh_path_search(e);
                c.publish(e);
            }),
        );
        // The route environment's providers are the picker's catalogue.
        workspace::on_config_changed(
            engine,
            hook(&self.me, |c, e| {
                c.refresh_catalogue(e);
                c.settle_modes(e);
                c.publish(e);
            }),
        );
        let settings = Settings::of(engine);
        settings.on_settings_changed(hook(&self.me, Composer::publish));
        settings.on_device_changed(hook(&self.me, Composer::publish));
        Keymap::of(engine).on_bindings_changed(hook(&self.me, Composer::publish));
        // The Space's page or images on show take the prompt.
        space::on_changed(engine, hook(&self.me, Composer::follow_page));
        space::on_prompt_page_changed(engine, hook(&self.me, Composer::follow_page));
        space::on_agent_ask_requested(engine, hook(&self.me, Composer::start_ask));
        space::on_image_offer_changed(
            engine,
            hook(&self.me, |c, e| {
                if c.on_images() {
                    c.publish(e);
                }
            }),
        );
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
    /// Whether the draft `draft_id`'s first message is still being made
    /// into a thread.
    pub fn launching(&self, draft_id: &str) -> bool {
        self.launching.contains(draft_id)
    }

    /// The thread or draft the window's composer writes to; empty with
    /// neither open (or the thread not listed).
    fn target(&self, engine: &Engine) -> String {
        if let Some(place) = self.place_target() {
            return place;
        }
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
        self.follow_place(engine, !self.thread.is_empty());
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
                        Out::TurnChanged | Out::AttachmentSigned { .. } => Composer::publish,
                        // A thread's messages are known once its stream is live.
                        Out::StatusChanged => Composer::reconcile_unsent,
                        _ => return,
                    };
                    let turn = matches!(out, Out::TurnChanged | Out::StatusChanged);
                    later(&me, engine, move |c, e| {
                        if c.timeline == Some(obj) {
                            f(c, e);
                        } else if turn {
                            // An edit outlives leaving its thread: it ends
                            // when its message leaves the queue all the same.
                            c.recover_queued_edits(e);
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
        let target = self.target(engine);
        self.ask_folder(engine, &target);
        let turn = self.turn_state(engine);
        // Ending an edit publishes everything already.
        let edits = kept::read(engine, |d| d.queued_edits.len());
        self.recover_queued_edits(engine);
        if kept::read(engine, |d| d.queued_edits.len()) != edits {
            return;
        }
        let composer = self.composer_state(engine, &turn);
        let picker = self.picker_state(engine);
        let stash = self.stash_state(engine);
        self.bridge.publish(engine, "turn", turn);
        self.bridge.publish(engine, "composer", composer);
        self.bridge.publish(engine, "modelPicker", picker);
        self.bridge.publish(engine, "composerStash", stash);
        // A file ties the draft to its machine, so the machine picker stops
        // reading "Auto balance" (workspace's auto_balanced).
        let files = !self.draft_id.is_empty() && kept::holds_files(engine, &self.draft_id);
        if files != self.held_files {
            self.held_files = files;
            workspace::refresh(engine);
        }
        // Every window lists the draft by what it holds, and marks a
        // thread's row while its composer holds something unsent.
        let edited = if self.draft_id.is_empty() {
            self.thread.clone()
        } else {
            self.draft_id.clone()
        };
        if !edited.is_empty() {
            Bridge::of(engine).defer(engine, move |engine| {
                controller::each_window(engine, |engine| {
                    controller::with::<Sidebar, _>(engine, |s, e| s.draft_edited(e, &edited));
                });
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

    /// Empties the thread's composer of its text, attachments and excerpts,
    /// in every window (the sidebar's `thread.draft.discard`); its model and
    /// modes stay.
    pub fn discard_draft(&mut self, engine: &Engine, target: &str) {
        let kept_one = kept::read(engine, |d| d.drafts.contains_key(target));
        if !kept_one || thread_of(engine, target).is_none() {
            return;
        }
        kept::edit_draft(engine, target, |kept| {
            kept.attachments.clear();
            kept.excerpts.clear();
        });
        self.set_text(engine, target, "", 0, &Json::Null);
        // The attachments went too, which the text alone does not save;
        // other windows' composers and every sidebar see the empty draft.
        kept::save(engine);
        let target = target.to_owned();
        Bridge::of(engine).defer(engine, move |engine| {
            controller::each_window(engine, |engine| {
                controller::with::<Sidebar, _>(engine, |s, e| s.draft_edited(e, &target));
            });
        });
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
        if let Some(selection) = self.page_base_selection(engine, key) {
            return selection;
        }
        if let Some(thread) = thread_of(engine, key) {
            return thread.model_selection;
        }
        let Some(draft) = drafts::draft(engine, key) else {
            return Obj::new();
        };
        let mut selection = project_selection(engine, &draft.environment_id, &draft.project_id);
        if selection.is_empty() {
            selection = Settings::of(engine)
                .value("defaultModelSelection")
                .map(|v| as_object(&v).clone())
                .unwrap_or_default();
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
        let remembered = |chosen: &mut Obj, instance: &str, model: &str| {
            if let Some(options) = kept::model_options(engine, instance, model) {
                chosen.insert("options".into(), options);
            }
        };
        let first_ready = || {
            let Some(ready) = self.catalogue.iter().find(|i| i.ready()) else {
                return Obj::new();
            };
            let own = model::default_model(ready);
            let mut next = Obj::new();
            next.insert("instanceId".into(), json!(ready.instance_id));
            next.insert("model".into(), json!(own));
            remembered(&mut next, &ready.instance_id, &own);
            next
        };
        let instance_id = field(&chosen, "instanceId").to_owned();
        let is_thread = thread_of(engine, target).is_some();
        // A started thread shows what it holds, unavailable as it may be:
        // what a send with no pick runs on is the thread's, never one made
        // up here.
        if instance_id.is_empty() {
            return if is_thread { chosen } else { first_ready() };
        }
        let instance = self.instance_of(&chosen);
        // A model saved under an alias is the built-in model it names, its
        // options kept; a custom model of that name is not it.
        if let Some(instance) = instance {
            let slug = model::fallback_model_slug(instance, field(&chosen, "model"));
            if !slug.is_empty() {
                chosen.insert("model".into(), json!(slug));
            }
        }
        let chosen_model = field(&chosen, "model").to_owned();
        if let Some(instance) = instance
            && instance.ready()
        {
            if chosen_model.is_empty() {
                chosen.insert("model".into(), json!(model::default_model(instance)));
            } else if !is_thread && model::find_model(instance, &chosen_model).is_empty() {
                // A draft still naming the model picked on another instance,
                // whose own catalogue has no such model: this instance's
                // default, with the options last given to it here.
                let own = model::default_model(instance);
                chosen.insert("model".into(), json!(own));
                chosen.remove("options");
                remembered(&mut chosen, &instance_id, &own);
            }
            return chosen;
        }
        if is_thread {
            return chosen;
        }
        // A draft's account cannot run a turn: another account of the same
        // driver that lists the model takes over, with the options last
        // given to the model there, or the ones picked for it here when it
        // has none of its own.
        if let Some(instance) = instance {
            for candidate in &self.catalogue {
                if !candidate.ready()
                    || candidate.driver != instance.driver
                    || candidate.instance_id == instance_id
                {
                    continue;
                }
                let slug = model::fallback_model_slug(candidate, &chosen_model);
                if slug.is_empty() {
                    continue;
                }
                chosen.insert("instanceId".into(), json!(candidate.instance_id));
                chosen.insert("model".into(), json!(slug));
                remembered(&mut chosen, &candidate.instance_id, &slug);
                return chosen;
            }
        }
        // A draft starts on the first provider that can run instead, and
        // keeps its own while none can (the providers have not arrived).
        let ready = first_ready();
        if ready.is_empty() { chosen } else { ready }
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

    /// The mode the user picked for the target, empty when none counts: a
    /// new thread keeps its pick until it starts, an existing thread only
    /// while the MC has not taken it. One kept past that (the app quit
    /// first, or a new thread's draft carried it in) would hide what the
    /// thread was given since, here or on another device.
    fn picked_runtime_mode(&self, engine: &Engine, target: &str) -> String {
        if thread_of(engine, target).is_some() && !self.setting_mode.contains_key(target) {
            return String::new();
        }
        kept::read(engine, |d| {
            d.drafts
                .get(target)
                .map(|k| k.runtime_mode.clone())
                .unwrap_or_default()
        })
    }

    fn runtime_mode_of(&self, engine: &Engine, target: &str) -> String {
        let own = self.picked_runtime_mode(engine, target);
        if !own.is_empty() {
            return own;
        }
        if let Some(mode) = self.page_runtime_mode(engine, target) {
            return mode;
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

    /// The permissions a new thread of the target's project starts in: the
    /// composer names a thread's own only when they differ from these.
    fn default_runtime_mode_of(&self, engine: &Engine, target: &str) -> String {
        if let Some(mode) = self.page_runtime_mode(engine, target) {
            return mode;
        }
        let project = thread_of(engine, target)
            .map(|thread| thread.project_id)
            .or_else(|| drafts::draft(engine, target).map(|draft| draft.project_id))
            .unwrap_or_default();
        let settings = Settings::of(engine);
        for path in [
            format!("projectSettingsOverrides.{project}.defaultRuntimeMode"),
            "defaultRuntimeMode".to_owned(),
        ] {
            if let Some(mode) = settings.value(&path).as_ref().and_then(Json::as_str)
                && !mode.is_empty()
            {
                return mode.to_owned();
            }
        }
        "full-access".into()
    }

    /// A new thread (`drafts::start_carrying` names `from` only then)
    /// opened on a draft with nothing of its own (just created, never
    /// written or picked in, or holding only what an earlier new thread
    /// carried) takes the mode as picked there or as the thread has it,
    /// and the model the same way unless the project has a default model
    /// of its own. A draft the user has started on keeps what it has.
    fn carry_into(&mut self, engine: &Engine, draft_id: &str, from: &str) {
        if from.is_empty() || from == draft_id {
            return;
        }
        let Some(started) = drafts::draft(engine, draft_id) else {
            return;
        };
        let before = kept::draft_of(engine, draft_id);
        let picked = !before.carried
            && (before.model_selection.is_some() || !before.interaction_mode.is_empty());
        if !started.text.is_empty()
            || picked
            || before.multiple_models.is_some()
            || before.carries()
        {
            return;
        }
        let mut draft = before.clone();
        // The mode the composer showed there.
        draft.interaction_mode = self.interaction_mode_of(engine, from);
        draft.model_selection = None;
        if project_selection(engine, &started.environment_id, &started.project_id).is_empty() {
            let model = kept::draft_of(engine, from)
                .model_selection
                .or_else(|| thread_of(engine, from).map(|t| t.model_selection))
                .unwrap_or_default();
            if !model.is_empty() {
                draft.model_selection = Some(model);
            }
        }
        draft.carried = true;
        if draft.interaction_mode == before.interaction_mode
            && draft.model_selection == before.model_selection
            && before.carried
        {
            return;
        }
        kept::edit_draft(engine, draft_id, |kept| *kept = draft);
        kept::save(engine);
        self.publish(engine);
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
        self.catalogues += 1;
    }

    /// A model picked in a started thread's draft gives way to what the
    /// thread holds once the thread moves past it, so a change made on
    /// another client shows here: with revisions, any change but this
    /// client's own (`next_pick`); from an MC that counts none, once the
    /// thread runs the pick (upstream #20886).
    pub(super) fn forget_taken_picks(&mut self, engine: &Engine) {
        let revisions: HashMap<String, Option<i64>> = self
            .own
            .keys()
            .map(|key| {
                (
                    key.clone(),
                    thread_of(engine, key).and_then(|t| t.selection_revision),
                )
            })
            .collect();
        self.own.retain(|key, changes| {
            let revision = revisions.get(key).copied().flatten();
            changes.retain(|change| {
                let change = change.borrow();
                !(change.answered && revision.is_none_or(|at| !change.ahead(at)))
            });
            !changes.is_empty()
        });
        let picks: Vec<String> = kept::read(engine, |d| {
            d.drafts
                .iter()
                .filter(|(_, k)| k.model_selection.is_some() && k.multiple_models.is_none())
                .map(|(key, _)| key.clone())
                .collect()
        });
        let threads: Vec<_> = picks
            .into_iter()
            .filter_map(|key| Some((thread_of(engine, &key)?, key)))
            .collect();
        if threads.is_empty() {
            return;
        }
        let forgot = kept::write(engine, |d| {
            let mut forgot = false;
            for (thread, key) in &threads {
                let Some(draft) = d.drafts.get_mut(key) else {
                    continue;
                };
                let base = draft.pick_base;
                if next_pick(draft, thread) {
                    forgot |= draft.pick_base != base;
                } else {
                    draft.drop_picks();
                    forgot = true;
                }
            }
            forgot
        });
        if forgot {
            kept::save(engine);
        }
    }

    /// Each pick is made fresh against what the thread holds now, with the
    /// own changes that may still move it on.
    pub(super) fn note_pick(&self, engine: &Engine, target: &str) {
        let revision = thread_of(engine, target).and_then(|t| t.selection_revision);
        let own: Vec<kept::OwnChange> = match revision {
            Some(at) => self
                .own
                .get(target)
                .into_iter()
                .flatten()
                .filter(|change| change.borrow().ahead(at))
                .cloned()
                .collect(),
            None => Vec::new(),
        };
        kept::edit_draft(engine, target, |draft| {
            draft.pick_base = revision;
            draft.pick_own = own;
        });
    }

    /// A mode change sent from here: the pick on the target stands past it.
    pub(super) fn own_sent(&mut self, engine: &Engine, target: &str) -> kept::OwnChange {
        let change = kept::OwnChange::new(std::cell::RefCell::new(kept::Own {
            sent_at: thread_of(engine, target).and_then(|t| t.selection_revision),
            ..kept::Own::default()
        }));
        self.own
            .entry(target.to_owned())
            .or_default()
            .push(change.clone());
        kept::write(engine, |d| {
            if let Some(draft) = d.drafts.get_mut(target)
                && draft.model_selection.is_some()
            {
                draft.pick_own.push(change.clone());
            }
        });
        change
    }

    pub(super) fn own_pending(&self, target: &str) -> bool {
        self.own
            .get(target)
            .is_some_and(|changes| changes.iter().any(|change| !change.borrow().answered))
    }

    /// The MC answers with the revision a change moved the thread to. An MC
    /// that counts revisions names one in every answer that moved the
    /// thread, and one that counts none never counts the change, so each
    /// thread's own MC decides.
    pub(super) fn own_answered(
        &mut self,
        engine: &Engine,
        target: &str,
        change: &kept::OwnChange,
        answer: Option<&Json>,
    ) {
        {
            let mut change = change.borrow_mut();
            change.answered = true;
            if let Some(moved) = answer.and_then(|a| a["selectionRevision"].as_i64()) {
                change.revision = Some(moved);
            }
        }
        // Sends that waited for the answers go now, made past this client's
        // own changes.
        if !self.own_pending(target) {
            for resume in self.after_own.remove(target).unwrap_or_default() {
                resume(self, engine);
            }
        }
        self.forget_taken_picks(engine);
        self.publish(engine);
    }

    /// A send the MC refused for a choice made against a selection the
    /// thread has since left (`selection-stale`): says what the thread is
    /// on now.
    pub(super) fn toast_stale(&self, engine: &Engine, detail: &Json) {
        let mut now = as_object(&detail["modelSelection"]).clone();
        if now.is_empty() {
            now = as_object(&detail["selection"]["modelSelection"]).clone();
        }
        let instance_id = field(&now, "instanceId");
        let chosen = field(&now, "model");
        let mut model_name = chosen.to_owned();
        let mut provider = instance_id.to_owned();
        if let Some(instance) = model::find(&self.catalogue, instance_id) {
            if !instance.display_name.is_empty() {
                provider = instance.display_name.clone();
            }
            let name = field(&model::find_model(instance, chosen), "name").to_owned();
            if !name.is_empty() {
                model_name = name;
            }
        }
        let place = if model_name.is_empty() || provider.is_empty() {
            "This thread changed elsewhere.".to_owned()
        } else {
            format!("This thread moved to {model_name} on {provider} elsewhere.")
        };
        toast(
            engine,
            "warning",
            "Message not sent",
            &format!("{place} Check it and send again."),
        );
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
        if target.starts_with("page#") || target.starts_with("images#") {
            return self.mc.environment();
        }
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

/// What becomes of a draft's model pick at its thread's row: false when it
/// gives way. The pick moves its base only across revisions this client's
/// own answers name. While one of its own changes is unanswered, that
/// change may be what moved the thread, so the pick waits, unmoved, for the
/// answer to say.
fn next_pick(draft: &mut Draft, thread: &crate::sidebar_model::Thread) -> bool {
    let (Some(revision), Some(base)) = (thread.selection_revision, draft.pick_base) else {
        return draft
            .model_selection
            .as_ref()
            .is_some_and(|pick| !model::pick_matches_thread(pick, &thread.model_selection));
    };
    if revision < base {
        return false;
    }
    if revision == base {
        return true;
    }
    let mut named = HashSet::new();
    let mut pending = 0;
    for change in &draft.pick_own {
        let change = change.borrow();
        if !change.answered {
            pending += 1;
        }
        if let Some(moved) = change.revision {
            named.insert(moved);
        }
    }
    let unaccounted = (base + 1..=revision)
        .filter(|at| !named.contains(at))
        .count();
    // Each unanswered change may yet name one revision; any more are
    // another client's.
    if unaccounted > pending {
        return false;
    }
    if unaccounted > 0 {
        return true;
    }
    draft.pick_base = Some(revision);
    draft.pick_own.retain(|change| {
        let change = change.borrow();
        !(change.answered && !change.ahead(revision))
    });
    true
}
