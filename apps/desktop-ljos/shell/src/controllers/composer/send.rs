//! Sending: a thread's follow-ups one at a time and in order, a new
//! thread's launch (placed, its images stored first), a launch on several
//! models, stop, and the prompts a quit or a drop cut off coming back.

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::rc::Rc;

use ljos::prelude::Engine;
use serde_json::json;

use super::attachments::{file_records, image_records};
use super::kept::{self, Attachment, Excerpt, Send, Unsent};
use super::text::{self, IMPLEMENT_PREFIX, launch_title, newest_user_message, prompt_problem};
use super::{
    Composer, back, later, now_iso, setting, string, thread_of, toast, toast_error, unanswered,
    uuid,
};
use crate::bridge::Bridge;
use crate::composer_model as model;
use crate::controller;
use crate::controllers::drafts;
use crate::controllers::navigation::{Navigation, Route};
use crate::controllers::toasts::{Action, DEFAULT_TIMEOUT_MS, Toasts};
use crate::controllers::workspace;
use crate::json::Json;
use crate::mc::McError;
use crate::store;
use crate::thread_view::summary::{Obj, as_object, text as field};
use crate::thread_view::timeline_model::TimelineModel;

/// How long a new thread waits on the MC to place it before it starts where
/// the user picked (desktop-qt's kPlacementWaitMs).
const PLACEMENT_WAIT_MS: i32 = 3000;

const NEWER_DRAFT: &str =
    "Your newer draft is unchanged. Restore the failed prompt when this composer is empty.";
const MULTIPLE_NEED_GIT: &str =
    "Multiple models need a new thread in a Git project. Each gets its own worktree.";

/// What a send gives back when it fails.
#[derive(Clone, Debug, Default)]
struct Prompt {
    text: String,
    attachments: Vec<Attachment>,
    excerpts: Vec<Excerpt>,
}

/// A new thread's launch on its way.
#[derive(Clone)]
struct Launching {
    draft_id: String,
    thread_id: String,
    message_id: String,
    background: bool,
    prompt: Prompt,
}

/// A send to several models, as their launches answer.
struct Batch {
    id: String,
    draft_id: String,
    prompt: Prompt,
    pending: Cell<usize>,
    started: Cell<usize>,
    unanswered: Cell<usize>,
    first: RefCell<String>,
}

/// One model's launch of a [`Batch`].
struct ModelLaunch {
    batch: Rc<Batch>,
    name: String,
    thread_key: String,
    message_id: String,
    environment_id: String,
}

type Placed = Box<dyn FnOnce(&mut Composer, &Engine, String, String)>;

fn not_connected(engine: &Engine) {
    toast(
        engine,
        "warning",
        "Not connected: message not sent",
        "Reconnecting to the environment. Try again once it is connected.",
    );
}

/// A success toast whose Open shows `thread_key`.
fn started(engine: &Engine, title: &str, thread_key: String) {
    let open = Action::new("Open", move |engine| {
        let route = Route::Thread(thread_key.clone());
        controller::with::<Navigation, _>(engine, |n, e| n.open(e, route));
    });
    controller::with::<Toasts, _>(engine, |t, e| {
        t.show(e, "success", title, "", Some(open), DEFAULT_TIMEOUT_MS);
    });
}

fn sticky_error(engine: &Engine, title: &str, description: &str, action: Action) {
    controller::with::<Toasts, _>(engine, |t, e| {
        t.show(e, "error", title, description, Some(action), 0);
    });
}

fn object(value: Json) -> Obj {
    match value {
        Json::Object(map) => map,
        _ => Obj::new(),
    }
}

/// The stored records `persistChatAttachments` answered, then the files.
fn stored(result: &Json, files: &[Json]) -> Json {
    let mut stored = result["attachments"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    stored.extend(files.iter().cloned());
    Json::Array(stored)
}

impl Composer {
    /// Stops the route thread's turn: its run, else the run it waits on or
    /// whose background tasks still run.
    pub(super) fn interrupt(&mut self, engine: &Engine) -> bool {
        let open = if self.draft_id.is_empty() {
            self.thread.clone()
        } else {
            String::new()
        };
        let Some(thread) = thread_of(engine, &open) else {
            return false;
        };
        let mut run_id = thread.active_run_id.clone();
        if run_id.is_none()
            && (thread.activity_run_status.as_deref() == Some("waiting")
                || thread.pending_background_tasks > 0)
        {
            run_id = thread.latest_run_id.clone();
        }
        let Some(run_id) = run_id else {
            return true;
        };
        // The turn the user stops here stays open once it settles.
        if let Some(obj) = self.timeline {
            TimelineModel::update(engine, obj, |t| t.keep_open(&run_id));
        }
        self.mc.dispatch_command(
            &thread.environment_id,
            json!({"type": "run.interrupt", "threadId": thread.id, "runId": run_id}),
            back(&self.me, |_, engine, result| {
                if let Err(error) = result {
                    toast_error(
                        engine,
                        "Failed to interrupt the current turn.",
                        &error.message,
                    );
                }
            }),
        );
        true
    }

    /// A send from the composer: the brick's text (else the draft's), with
    /// the draft's images, model and modes. During a turn it follows the
    /// follow-up setting (`followUpBehavior`, steer by default), the
    /// alternate intent the other way; with the thread idle on a proposed
    /// plan it refines the plan (or implements it, with no text).
    pub(super) fn submit(&mut self, engine: &Engine, payload: &Json) -> bool {
        let target = self.target(engine);
        if target.is_empty() {
            return true;
        }
        let text = if payload.get("text").is_some() {
            string(payload, "text")
        } else {
            kept::draft(engine, &target)
        };
        // The submit is the brick's newest edit, so it takes the cleared (or
        // restored) text as the answer to it.
        let end = model::utf16_len(&text) as i64;
        self.set_text(
            engine,
            &target,
            &text,
            end,
            payload.get("edit").unwrap_or(&Json::Null),
        );
        if let Some(problem) = prompt_problem(&text) {
            toast_error(engine, "Message not sent", &problem);
            return true;
        }
        let editing = kept::read(engine, |d| {
            d.queued_edit.as_ref().is_some_and(|e| e.thread == target)
        });
        if editing {
            return self.save_queued_edit(engine, &target, &text);
        }
        if self.slash_mode(engine, &target, &text)
            || self.slash_usage_limits(engine, &target, &text)
        {
            return true;
        }
        // The next message closes the limits "/usage-limits" opened.
        if !text.trim().is_empty() {
            self.usage_limits.remove(&target);
        }
        if !self.draft_id.is_empty() {
            return self.submit_draft(engine, &target, payload);
        }
        let has_extras = kept::draft_of(engine, &target).carries();
        let plan_follow_up = !has_extras && !self.turn_state(engine)["plan"].is_null();
        if text.trim().is_empty() && !has_extras && !plan_follow_up {
            return true;
        }
        let running = thread_of(engine, &target).is_some_and(|t| t.active_run_id.is_some());
        let mut mode = "auto";
        if running {
            let queue = setting(engine, "followUpBehavior").as_str() == Some("queue");
            let alternate = string(payload, "intent") == "alternate";
            mode = if queue != alternate { "queue" } else { "steer" };
        }
        self.send_turn(engine, &target, &text, mode, plan_follow_up, true)
    }

    /// A thread's follow-up (or the plan's implementation, `from_draft`
    /// false, which leaves the draft alone): the mode and provider changes,
    /// then the message, queued behind the thread's sends in flight.
    pub(super) fn send_turn(
        &mut self,
        engine: &Engine,
        target: &str,
        text: &str,
        mode: &str,
        plan_follow_up: bool,
        from_draft: bool,
    ) -> bool {
        let Some(thread) = thread_of(engine, target) else {
            return false;
        };
        // Nothing leaves while the MC is out of reach: the draft stays as it
        // is.
        if !self.mc.is_ready() || !store::with(engine, |s| s.thread_online(target)) {
            not_connected(engine);
            return true;
        }
        if from_draft
            && self.files_block(
                engine,
                &kept::draft_of(engine, target).attachments,
                "sending",
            )
        {
            return true;
        }
        // Nor while the thread is on its way to another machine, which would
        // refuse it.
        if let Some(to) = &thread.moving_to {
            toast(
                engine,
                "warning",
                &format!("{} is moving to {to}", thread.title),
                "Send the message once it has arrived.",
            );
            return true;
        }
        let trimmed = text.trim();
        let mut plan = Obj::new();
        if plan_follow_up {
            plan = as_object(&self.turn_state(engine)["plan"]).clone();
            if plan.is_empty() {
                return true;
            }
        }
        let implement = plan_follow_up && trimmed.is_empty();

        let created_at = now_iso(engine);
        // Only a mode the user changed is set; a thread the MC has no mode
        // for keeps the MC's default.
        let runtime_mode = kept::read(engine, |d| {
            d.drafts
                .get(target)
                .map(|k| k.runtime_mode.clone())
                .unwrap_or_default()
        });
        let mut interaction_mode = self.interaction_mode_of(engine, target);
        if plan_follow_up {
            interaction_mode = if implement { "default" } else { "plan" }.into();
        }
        if thread.interaction_mode.is_empty() && interaction_mode == "default" {
            interaction_mode.clear();
        }
        let mut commands: Vec<Obj> = Vec::new();
        if !runtime_mode.is_empty() && runtime_mode != thread.runtime_mode {
            commands.push(object(json!({
                "type": "thread.runtime-mode.set",
                "threadId": thread.id,
                "runtimeMode": runtime_mode,
                "createdAt": created_at,
            })));
        }
        if !interaction_mode.is_empty() && interaction_mode != thread.interaction_mode {
            commands.push(object(json!({
                "type": "thread.interaction-mode.set",
                "threadId": thread.id,
                "interactionMode": interaction_mode,
                "createdAt": created_at,
            })));
        }
        // Another provider takes the thread over, handed its conversation by
        // the MC.
        let model_selection = self.selection(engine, target);
        let instance_id = field(&model_selection, "instanceId");
        if !instance_id.is_empty() && instance_id != field(&thread.model_selection, "instanceId") {
            commands.push(object(json!({
                "type": "provider.switch",
                "threadId": thread.id,
                "modelSelection": model_selection,
                "createdAt": created_at,
            })));
        }
        let message_id = uuid();
        let message_text = if implement {
            format!("{IMPLEMENT_PREFIX}{}", field(&plan, "markdown").trim())
        } else {
            trimmed.to_owned()
        };
        let title_seed = if plan_follow_up || trimmed.is_empty() {
            thread.title.clone()
        } else {
            trimmed.to_owned()
        };
        let mut message = object(json!({
            "type": "message.dispatch",
            "createdBy": "user",
            "creationSource": "web",
            "threadId": thread.id,
            "messageId": message_id,
            "text": message_text,
            "attachments": [],
            "titleSeed": title_seed,
        }));
        if !model_selection.is_empty() {
            message.insert(
                "modelSelection".into(),
                Json::Object(model_selection.clone()),
            );
        }
        self.remember_model(engine, &model_selection);
        if implement {
            message.insert(
                "sourcePlanRef".into(),
                json!({"threadId": thread.id, "planId": field(&plan, "id")}),
            );
        }
        // The MC resolves the context.
        if mode == "queue" {
            message.insert("dispatchMode".into(), json!({"type": "queue_after_active"}));
        } else {
            message.insert("deliveryIntent".into(), json!(mode));
            message.insert("dispatchMode".into(), json!({"type": "start_immediately"}));
        }
        // Implementing from the plan's own button leaves the draft alone.
        let (attachments, excerpts) = kept::edit_draft(engine, target, |kept| {
            if plan_follow_up {
                kept.interaction_mode = interaction_mode.clone();
            }
            if from_draft {
                (
                    std::mem::take(&mut kept.attachments),
                    std::mem::take(&mut kept.excerpts),
                )
            } else {
                (Vec::new(), Vec::new())
            }
        });
        text::with_excerpts(&mut message, &excerpts);
        commands.push(message);
        // Sending again is newer than what a restart left of the thread's
        // sends.
        kept::write(engine, |d| {
            d.unsent.retain(|u| !(u.kept && u.target == target))
        });
        let after = self.newest_before(engine, target);
        let prompt = if from_draft {
            text.to_owned()
        } else {
            String::new()
        };
        let first = kept::write(engine, |d| {
            // Kept until the MC answers.
            if from_draft && (!text.is_empty() || !attachments.is_empty() || !excerpts.is_empty()) {
                d.unsent.push(Unsent {
                    target: target.to_owned(),
                    thread: target.to_owned(),
                    message_id: message_id.clone(),
                    after,
                    prompt: text.to_owned(),
                    attachments: attachments.clone(),
                    excerpts: excerpts.clone(),
                    ..Unsent::default()
                });
            }
            // A send made while an earlier one is still in flight waits its
            // turn.
            let queue = d.queues.entry(target.to_owned()).or_default();
            queue.push_back(Send {
                target: target.to_owned(),
                environment_id: thread.environment_id.clone(),
                thread_id: thread.id.clone(),
                commands,
                attachments,
                excerpts,
                prompt,
                message_id,
            });
            queue.len() == 1
        });
        if from_draft {
            self.set_text_end(engine, target, "");
        }
        kept::save(engine);
        self.publish(engine);
        if first {
            self.send_next(engine, target);
        }
        true
    }

    /// Uploads the thread's oldest send's images, dispatches it command by
    /// command, then the next send.
    fn send_next(&mut self, engine: &Engine, target: &str) {
        let Some(send) = kept::read(engine, |d| {
            d.queues.get(target).and_then(|q| q.front().cloned())
        }) else {
            return;
        };
        let files = file_records(&send.attachments);
        if send.attachments.iter().all(|a| a.file) {
            let mut ready = send;
            if !files.is_empty()
                && let Some(message) = ready.commands.last_mut()
            {
                message.insert("attachments".into(), Json::Array(files));
            }
            self.dispatch_all(ready, 0);
            return;
        }
        let message = send.commands.last().cloned().unwrap_or_default();
        let payload = json!({
            "threadId": send.thread_id,
            "messageId": message.get("messageId").cloned().unwrap_or(Json::Null),
            "attachments": image_records(&send.attachments),
        });
        let environment_id = send.environment_id.clone();
        self.mc.call(
            &environment_id,
            "assets.persistChatAttachments",
            payload,
            back(&self.me, move |c, engine, result| match result {
                Err(error) => c.finish_send(engine, &send.target, Some(error)),
                Ok(result) => {
                    let mut carried = send;
                    if let Some(message) = carried.commands.last_mut() {
                        message.insert("attachments".into(), stored(&result, &files));
                    }
                    c.dispatch_all(carried, 0);
                }
            }),
        );
    }

    /// The send's commands, one after another.
    fn dispatch_all(&mut self, send: Send, index: usize) {
        let Some(command) = send.commands.get(index).cloned() else {
            return;
        };
        let environment_id = send.environment_id.clone();
        self.mc.dispatch_command(
            &environment_id,
            Json::Object(command),
            back(&self.me, move |c, engine, result| match result {
                Ok(_) if index + 1 < send.commands.len() => c.dispatch_all(send, index + 1),
                Ok(_) => c.finish_send(engine, &send.target, None),
                Err(error) => c.finish_send(engine, &send.target, Some(error)),
            }),
        );
    }

    /// The thread's oldest send was answered.
    fn finish_send(&mut self, engine: &Engine, target: &str, error: Option<McError>) {
        if let Some(error) = error {
            // The sends queued behind it would reach the MC out of order, so
            // they stop too and come back with it.
            let unsent: Vec<Send> = kept::write(engine, |d| d.queues.remove(target))
                .map(Vec::from)
                .unwrap_or_default();
            if unanswered(&error) {
                // The MC may have the first: the thread's messages tell once
                // it is back, and the ones behind it come back with it or
                // without it.
                for queued in &unsent {
                    self.keep_unanswered(engine, &queued.message_id, Obj::new());
                }
                self.publish(engine);
                return;
            }
            let mut prompts = Vec::new();
            let mut attachments = Vec::new();
            let mut excerpts = Vec::new();
            for queued in unsent {
                if !queued.prompt.is_empty() {
                    prompts.push(queued.prompt);
                }
                attachments.extend(queued.attachments);
                excerpts.extend(queued.excerpts);
                self.forget_unsent(engine, &queued.message_id);
            }
            let restored = prompts.join("\n\n");
            // Only into an untouched draft: newer typing is the user's, and
            // the toast gives the prompt back once the draft is empty.
            if restored.is_empty() || kept::draft(engine, target).is_empty() {
                toast_error(engine, "Failed to send message", &error.message);
                if !restored.is_empty() {
                    self.set_text_end(engine, target, &restored);
                }
            } else {
                self.offer_restore(
                    engine,
                    target,
                    "Failed to send message",
                    NEWER_DRAFT,
                    Prompt {
                        text: restored,
                        ..Prompt::default()
                    },
                );
            }
            kept::edit_draft(engine, target, |kept| {
                attachments.append(&mut kept.attachments);
                kept.attachments = attachments;
                excerpts.append(&mut kept.excerpts);
                kept.excerpts = excerpts;
            });
            kept::save(engine);
            self.publish(engine);
            return;
        }
        // A draft's first turn makes it a thread (a no-op for a thread the MC
        // already has).
        drafts::promote(engine, target);
        let next = kept::write(engine, |d| {
            let queue = d.queues.get_mut(target)?;
            let delivered = queue.pop_front()?.message_id;
            let more = !queue.is_empty();
            if !more {
                d.queues.remove(target);
            }
            // The sends behind it come after it in the thread.
            for unsent in &mut d.unsent {
                if unsent.target == target && !unsent.kept && unsent.after.is_some() {
                    unsent.after = Some(delivered.clone());
                }
            }
            d.delivered.insert(target.to_owned(), delivered.clone());
            Some((delivered, more))
        });
        let Some((delivered, more)) = next else {
            return;
        };
        self.forget_unsent(engine, &delivered);
        if more {
            self.send_next(engine, target);
        } else {
            self.publish(engine);
        }
    }

    /// Where a new thread starts. With more than one machine in the cluster
    /// the MC this shell is connected to chooses (`hal-c2.placeThread`): it
    /// answers the user's own pick while balancing is off or no machine has
    /// more room, else another machine and its checkout of the repository.
    /// The pick stands for a draft the user tied to its machine, and
    /// whenever the MC cannot be followed: it refuses, takes longer than
    /// [`PLACEMENT_WAIT_MS`], or names a project or machine this shell
    /// cannot reach. Balancing never holds a first message back.
    fn place(
        &mut self,
        engine: &Engine,
        environment_id: &str,
        project_id: &str,
        tied: bool,
        instance_id: &str,
        then: Placed,
    ) {
        let mut machines = store::with(engine, |s| s.environments());
        machines.sort();
        machines.dedup();
        if tied || machines.len() < 2 {
            then(
                self,
                engine,
                environment_id.to_owned(),
                project_id.to_owned(),
            );
            return;
        }
        let mut input = json!({"environmentId": environment_id, "projectId": project_id});
        if !instance_id.is_empty() {
            input["instanceId"] = json!(instance_id);
        }
        // The MC's answer or the wait running out, whichever is first.
        let pending: Rc<RefCell<Option<Placed>>> = Rc::new(RefCell::new(Some(then)));
        let timer: Rc<Cell<Option<ljos::prelude::ObjectId>>> = Rc::new(Cell::new(None));
        let answer = {
            let (pending, timer) = (pending.clone(), timer.clone());
            let picked = (environment_id.to_owned(), project_id.to_owned());
            move |c: &mut Composer, engine: &Engine, result: Result<Json, McError>| {
                let Some(then) = pending.borrow_mut().take() else {
                    return;
                };
                if let Some(timer) = timer.take() {
                    controller::stop_timer(engine, timer);
                }
                let placed = result.unwrap_or(Json::Null);
                let on = placed["environmentId"]
                    .as_str()
                    .unwrap_or_default()
                    .to_owned();
                let into = placed["projectId"].as_str().unwrap_or_default().to_owned();
                let reachable = !on.is_empty()
                    && store::with(engine, |s| {
                        s.environment_online(&on) && s.project_row(&on, &into).is_some()
                    });
                if reachable {
                    then(c, engine, on, into);
                } else {
                    then(c, engine, picked.0, picked.1);
                }
            }
        };
        let answer = Rc::new(RefCell::new(Some(answer)));
        let replied = answer.clone();
        self.mc.call(
            &self.mc.environment(),
            "hal-c2.placeThread",
            input,
            back(&self.me, move |c, engine, result| {
                if let Some(answer) = replied.borrow_mut().take() {
                    answer(c, engine, result);
                }
            }),
        );
        let native = ljos_engine::Timer {
            interval: PLACEMENT_WAIT_MS,
            repeat: false,
            running: true,
            ..ljos_engine::Timer::default()
        };
        let Ok(id) = engine.create_native(native, Some(Bridge::of(engine).object())) else {
            return;
        };
        timer.set(Some(id));
        let me = self.me.clone();
        let fired = engine.connect_by_name(id, "triggered", move |engine, _| {
            let Some(answer) = answer.borrow_mut().take() else {
                return;
            };
            later(&me, engine, move |c, e| {
                answer(c, e, Err(McError::new("no answer")))
            });
        });
        if fired.is_err() || engine.complete(id).is_err() {
            timer.set(None);
            controller::stop_timer(engine, id);
        }
    }

    /// A new thread's first send: the thread is placed, its images stored,
    /// then it is launched with the message in the draft's checkout (or the
    /// one it was placed in). The draft empties as it is sent, as a
    /// follow-up's composer does, and gets its text and images back if the
    /// launch fails; once the MC confirms, the window shows the thread in
    /// its place. A background send leaves the window on the draft, emptied
    /// for another prompt.
    fn submit_draft(&mut self, engine: &Engine, draft_id: &str, payload: &Json) -> bool {
        let Some(draft) = drafts::draft(engine, draft_id) else {
            return true;
        };
        let background = string(payload, "intent") == "background";
        let text = draft.text.clone();
        let kept = kept::draft_of(engine, draft_id);
        let mut attachments = kept.attachments;
        let excerpts = kept.excerpts;
        if text.trim().is_empty() && attachments.is_empty() && excerpts.is_empty() {
            return true;
        }
        if self.launching.contains(draft_id) {
            return true;
        }
        let place = workspace::launch(engine, draft_id);
        if !place.problem.is_empty() {
            toast_error(engine, "Could not create thread", &place.problem);
            return true;
        }
        if !self.mc.is_ready()
            || !store::with(engine, |s| s.environment_online(&place.environment_id))
        {
            not_connected(engine);
            return true;
        }
        // A file sent to another machine before the draft moved goes up
        // again.
        let mut moved = false;
        for attachment in attachments.clone() {
            if !attachment.file
                || !attachment.upload.is_empty()
                || attachment.environment_id == place.environment_id
            {
                continue;
            }
            moved = true;
            self.upload_file(engine, &attachment.id, &place.environment_id);
        }
        if moved {
            attachments = kept::draft_of(engine, draft_id).attachments;
        }
        if self.files_block(engine, &attachments, "sending") {
            return true;
        }
        let trimmed = text.trim();
        let model_selection = self.selection(engine, draft_id);
        let message_id = uuid();
        let first_name = attachments.first().map(|a| a.name.as_str()).unwrap_or("");
        let mut initial = object(json!({
            "messageId": message_id,
            "text": trimmed,
            "attachments": [],
        }));
        text::with_excerpts(&mut initial, &excerpts);
        let mut input = object(json!({
            "commandId": uuid(),
            "creationSource": "web",
            "threadId": draft.thread_id,
            "projectId": place.project_id,
            "title": launch_title(trimmed, first_name),
            "generateTitle": true,
            "runtimeMode": self.runtime_mode_of(engine, draft_id),
            "interactionMode": self.interaction_mode_of(engine, draft_id),
            "workspaceStrategy": place.strategy,
            "initialMessage": initial,
        }));
        if !model_selection.is_empty() {
            input.insert(
                "modelSelection".into(),
                Json::Object(model_selection.clone()),
            );
        }
        self.remember_model(engine, &model_selection);
        let prompt = Prompt {
            text,
            attachments,
            excerpts,
        };

        let multiple = kept::read(engine, |d| {
            d.drafts
                .get(draft_id)
                .and_then(|k| k.multiple_models.clone())
        });
        if let Some(models) = multiple {
            return self.submit_to_models(
                engine,
                draft_id,
                models,
                input,
                &place.strategy,
                &place.environment_id,
                prompt,
            );
        }
        // The prompt leaves the composer as a follow-up's does, and comes
        // back if the launch fails.
        let thread_id = draft.thread_id.clone();
        kept::write(engine, |d| {
            if let Some(kept) = d.drafts.get_mut(draft_id) {
                kept.attachments.clear();
                kept.excerpts.clear();
            }
            // Kept, before the draft lets go of it, until the MC answers the
            // launch.
            d.unsent.push(Unsent {
                target: draft_id.to_owned(),
                thread: format!("{}:{thread_id}", place.environment_id),
                message_id: message_id.clone(),
                after: None,
                prompt: prompt.text.clone(),
                attachments: prompt.attachments.clone(),
                excerpts: prompt.excerpts.clone(),
                ..Unsent::default()
            });
        });
        kept::save(engine);
        if background {
            // The thread is on its way; the draft takes the next prompt under
            // a new thread id, so the launched thread's row does not end it.
            drafts::renew(engine, draft_id);
        } else {
            self.launching.insert(draft_id.to_owned());
        }
        self.set_text_end(engine, draft_id, "");
        self.publish(engine);
        // Files already went to the machine the user picked, so the thread
        // starts there.
        let has_files = prompt.attachments.iter().any(|a| a.file);
        let job = Launching {
            draft_id: draft_id.to_owned(),
            thread_id,
            message_id,
            background,
            prompt,
        };
        let picked = place.clone();
        self.place(
            engine,
            &place.environment_id,
            &place.project_id,
            place.tied || has_files,
            field(&model_selection, "instanceId"),
            Box::new(move |c, engine, environment_id, project_id| {
                let mut input = input;
                if environment_id != picked.environment_id || project_id != picked.project_id {
                    input.insert("projectId".into(), json!(project_id));
                    // The branch this machine's checkout is on says nothing of
                    // another's; a new worktree's base is the repository's on
                    // either.
                    let mut strategy = picked.strategy.clone();
                    if field(&strategy, "type") == "root" {
                        strategy.remove("branch");
                    }
                    input.insert("workspaceStrategy".into(), Json::Object(strategy));
                }
                c.begin_launch(engine, job, environment_id, input);
            }),
        );
        true
    }

    /// The images go to the machine the thread starts on, then the thread
    /// does.
    fn begin_launch(
        &mut self,
        engine: &Engine,
        job: Launching,
        environment_id: String,
        mut input: Obj,
    ) {
        let thread = format!("{environment_id}:{}", job.thread_id);
        kept::write(engine, |d| {
            for unsent in &mut d.unsent {
                if unsent.message_id == job.message_id {
                    unsent.thread = thread.clone();
                }
            }
        });
        kept::save(engine);
        let files = file_records(&job.prompt.attachments);
        let mut message = as_object(input.get("initialMessage").unwrap_or(&Json::Null)).clone();
        if job.prompt.attachments.iter().all(|a| a.file) {
            if !files.is_empty() {
                message.insert("attachments".into(), Json::Array(files));
                input.insert("initialMessage".into(), Json::Object(message));
            }
            self.start_launch(job, environment_id, input);
            return;
        }
        let payload = json!({
            "threadId": job.thread_id,
            "messageId": message.get("messageId").cloned().unwrap_or(Json::Null),
            "attachments": image_records(&job.prompt.attachments),
        });
        self.mc.call(
            &environment_id.clone(),
            "assets.persistChatAttachments",
            payload,
            back(&self.me, move |c, engine, result| match result {
                Err(error) => {
                    c.forget_unsent(engine, &job.message_id);
                    c.launch_answered(engine, &job, String::new(), Some(error));
                }
                Ok(result) => {
                    message.insert("attachments".into(), stored(&result, &files));
                    input.insert("initialMessage".into(), Json::Object(message));
                    c.start_launch(job, environment_id, input);
                }
            }),
        );
    }

    fn start_launch(&mut self, job: Launching, environment_id: String, input: Obj) {
        self.mc.call(
            &environment_id.clone(),
            "orchestration.launchThread",
            Json::Object(input.clone()),
            back(&self.me, move |c, engine, result| {
                if let Err(error) = &result
                    && unanswered(error)
                {
                    // The thread may be there: the draft becomes it if so
                    // (drafts' reconcile), else it is asked for again.
                    c.keep_unanswered(engine, &job.message_id, input);
                    c.launching.remove(&job.draft_id);
                    c.publish(engine);
                    return;
                }
                c.forget_unsent(engine, &job.message_id);
                let mut thread_id = result
                    .as_ref()
                    .ok()
                    .and_then(|r| r["threadId"].as_str())
                    .unwrap_or_default()
                    .to_owned();
                if thread_id.is_empty() {
                    thread_id = field(&input, "threadId").to_owned();
                }
                let thread_key = format!("{environment_id}:{thread_id}");
                c.launch_answered(engine, &job, thread_key, result.err());
            }),
        );
    }

    fn launch_answered(
        &mut self,
        engine: &Engine,
        job: &Launching,
        thread_key: String,
        error: Option<McError>,
    ) {
        if job.background {
            self.launched_in_background(engine, job, thread_key, error);
        } else {
            self.launched(engine, job, &thread_key, error);
        }
    }

    /// The launch's answer: the draft becomes the thread, or gets its prompt
    /// back with a toast.
    fn launched(
        &mut self,
        engine: &Engine,
        job: &Launching,
        thread_key: &str,
        error: Option<McError>,
    ) {
        self.launching.remove(&job.draft_id);
        if let Some(error) = error {
            self.restore_launch(engine, &job.draft_id, &job.prompt);
            toast_error(engine, "Could not create thread", &error.message);
            self.publish(engine);
            return;
        }
        workspace::forget_draft(engine, &job.draft_id);
        drafts::promote_draft(engine, &job.draft_id, thread_key);
        kept::write(engine, |d| d.drafts.remove(&job.draft_id));
        kept::save(engine);
        self.publish(engine);
    }

    /// A failed launch's prompt back in its draft. Only into an empty one:
    /// newer typing is the user's.
    fn restore_launch(&mut self, engine: &Engine, draft_id: &str, prompt: &Prompt) -> bool {
        if drafts::draft(engine, draft_id).is_none()
            || !kept::draft(engine, draft_id).is_empty()
            || kept::draft_of(engine, draft_id).carries()
        {
            return false;
        }
        kept::edit_draft(engine, draft_id, |kept| {
            kept.attachments = prompt.attachments.clone();
            kept.excerpts = prompt.excerpts.clone();
        });
        // The draft keeps its text; the images and excerpts are the
        // composer's.
        kept::save(engine);
        self.set_text_end(engine, draft_id, &prompt.text);
        true
    }

    /// A background launch's answer: a toast that opens the new thread, or
    /// the prompt back in the draft (or, when the draft has a newer prompt,
    /// a toast that gives it back once the draft is empty).
    fn launched_in_background(
        &mut self,
        engine: &Engine,
        job: &Launching,
        thread_key: String,
        error: Option<McError>,
    ) {
        let Some(error) = error else {
            started(engine, "Started 1 thread in background", thread_key);
            return;
        };
        if self.restore_launch(engine, &job.draft_id, &job.prompt) {
            toast_error(
                engine,
                "A background prompt could not be sent",
                &error.message,
            );
            return;
        }
        let me = self.me.clone();
        let (draft_id, prompt) = (job.draft_id.clone(), job.prompt.clone());
        let restore = Action::new("Restore prompt", move |engine| {
            let (draft_id, prompt) = (draft_id.clone(), prompt.clone());
            later(&me, engine, move |c, engine| {
                if !c.restore_launch(engine, &draft_id, &prompt) {
                    return;
                }
                controller::with::<Navigation, _>(engine, |n, e| n.open(e, Route::Draft(draft_id)));
            });
        });
        sticky_error(
            engine,
            "A background prompt could not be sent",
            NEWER_DRAFT,
            restore,
        );
    }

    /// Send to multiple models: each gets a thread of its own, in a new
    /// worktree off the draft's branch, and the draft is ready for the next
    /// prompt. A thread that fails to start says so; if none starts the
    /// prompt comes back, then or, for launches a quit or drop left
    /// unanswered, once the shell shows none of their threads.
    #[allow(clippy::too_many_arguments)]
    fn submit_to_models(
        &mut self,
        engine: &Engine,
        draft_id: &str,
        models: Vec<Obj>,
        input: Obj,
        strategy: &Obj,
        environment_id: &str,
        prompt: Prompt,
    ) -> bool {
        let base = match field(strategy, "type") {
            "worktree" => field(strategy, "baseRef"),
            "root" => field(strategy, "branch"),
            _ => "",
        };
        if base.is_empty() {
            toast(
                engine,
                "warning",
                "Choose models and a base branch",
                MULTIPLE_NEED_GIT,
            );
            return true;
        }
        let mut worktree = json!({"type": "worktree", "baseRef": base});
        if strategy
            .get("startFromOrigin")
            .and_then(Json::as_bool)
            .unwrap_or(false)
        {
            worktree["startFromOrigin"] = json!(true);
        }
        kept::edit_draft(engine, draft_id, |kept| {
            kept.attachments.clear();
            kept.excerpts.clear();
        });
        drafts::renew(engine, draft_id);
        self.set_text_end(engine, draft_id, "");

        let images = image_records(&prompt.attachments);
        let files = file_records(&prompt.attachments);
        let batch = Rc::new(Batch {
            id: uuid(),
            draft_id: draft_id.to_owned(),
            pending: Cell::new(models.len()),
            started: Cell::new(0),
            unanswered: Cell::new(0),
            first: RefCell::new(String::new()),
            prompt,
        });
        for chosen in models {
            let mut launch = input.clone();
            let mut message =
                as_object(launch.get("initialMessage").unwrap_or(&Json::Null)).clone();
            let thread_id = uuid();
            let message_id = uuid();
            message.insert("messageId".into(), json!(message_id));
            message.insert("attachments".into(), Json::Array(files.clone()));
            launch.insert("commandId".into(), json!(uuid()));
            launch.insert("threadId".into(), json!(thread_id));
            let name = field(&chosen, "model").to_owned();
            launch.insert("modelSelection".into(), Json::Object(chosen));
            launch.insert("workspaceStrategy".into(), worktree.clone());
            launch.insert("initialMessage".into(), Json::Object(message.clone()));
            let thread_key = format!("{environment_id}:{thread_id}");
            // Kept until the MC answers this model's launch.
            kept::write(engine, |d| {
                d.unsent.push(Unsent {
                    target: draft_id.to_owned(),
                    thread: thread_key.clone(),
                    message_id: message_id.clone(),
                    after: None,
                    prompt: batch.prompt.text.clone(),
                    attachments: batch.prompt.attachments.clone(),
                    excerpts: batch.prompt.excerpts.clone(),
                    batch: batch.id.clone(),
                    ..Unsent::default()
                });
            });
            let one = ModelLaunch {
                batch: batch.clone(),
                name,
                thread_key,
                message_id: message_id.clone(),
                environment_id: environment_id.to_owned(),
            };
            if images.is_empty() {
                self.start_model(one, launch);
                continue;
            }
            let files = files.clone();
            self.mc.call(
                environment_id,
                "assets.persistChatAttachments",
                json!({"threadId": thread_id, "messageId": message_id, "attachments": images}),
                back(&self.me, move |c, engine, result| match result {
                    // No thread was launched, whatever became of the images.
                    Err(error) => c.settle_model(engine, &one, Some(error), false, Obj::new()),
                    Ok(result) => {
                        message.insert("attachments".into(), stored(&result, &files));
                        launch.insert("initialMessage".into(), Json::Object(message));
                        c.start_model(one, launch);
                    }
                }),
            );
        }
        kept::save(engine);
        self.publish(engine);
        true
    }

    fn start_model(&mut self, one: ModelLaunch, launch: Obj) {
        let environment_id = one.environment_id.clone();
        self.mc.call(
            &environment_id,
            "orchestration.launchThread",
            Json::Object(launch.clone()),
            back(&self.me, move |c, engine, result| {
                let lost = matches!(&result, Err(error) if unanswered(error));
                c.settle_model(engine, &one, result.err(), lost, launch);
            }),
        );
    }

    fn settle_model(
        &mut self,
        engine: &Engine,
        one: &ModelLaunch,
        error: Option<McError>,
        lost: bool,
        launch: Obj,
    ) {
        let batch = &one.batch;
        if lost {
            self.keep_unanswered(engine, &one.message_id, launch);
            batch.unanswered.set(batch.unanswered.get() + 1);
        } else if let Some(error) = error {
            self.forget_unsent(engine, &one.message_id);
            toast_error(
                engine,
                &format!("Could not start a thread on {}", one.name),
                &error.message,
            );
        } else {
            // A thread has the prompt: none of the launches brings it back.
            let removed = kept::write(engine, |d| {
                let before = d.unsent.len();
                d.unsent.retain(|u| u.batch != batch.id);
                d.unsent.len() != before
            });
            if removed {
                kept::save(engine);
            }
            if batch.started.get() == 0 {
                *batch.first.borrow_mut() = one.thread_key.clone();
            }
            batch.started.set(batch.started.get() + 1);
        }
        batch.pending.set(batch.pending.get().saturating_sub(1));
        if batch.pending.get() > 0 {
            return;
        }
        let count = batch.started.get();
        if count > 0 {
            let title = if count == 1 {
                "Started 1 thread in background".to_owned()
            } else {
                format!("Started {count} threads in background")
            };
            started(engine, &title, batch.first.borrow().clone());
            return;
        }
        // Nothing started: the prompt goes back into an untouched draft,
        // unless a launch may have (reconcile_unsent).
        if batch.unanswered.get() > 0
            || drafts::draft(engine, &batch.draft_id).is_none()
            || !kept::draft(engine, &batch.draft_id).is_empty()
        {
            return;
        }
        kept::edit_draft(engine, &batch.draft_id, |kept| {
            kept.attachments = batch.prompt.attachments.clone();
            kept.excerpts = batch.prompt.excerpts.clone();
        });
        kept::save(engine);
        self.set_text_end(engine, &batch.draft_id, &batch.prompt.text);
    }

    /// A sticky toast that gives `prompt` back to `target` once its draft
    /// is empty, and shows it.
    fn offer_restore(
        &self,
        engine: &Engine,
        target: &str,
        title: &str,
        description: &str,
        prompt: Prompt,
    ) {
        let me = self.me.clone();
        let target = target.to_owned();
        let restore = Action::new("Restore prompt", move |engine| {
            let (target, prompt) = (target.clone(), prompt.clone());
            later(&me, engine, move |c, engine| {
                if !kept::draft(engine, &target).is_empty() {
                    return;
                }
                kept::edit_draft(engine, &target, |kept| {
                    let mut attachments = prompt.attachments;
                    attachments.append(&mut kept.attachments);
                    kept.attachments = attachments;
                    let mut excerpts = prompt.excerpts;
                    excerpts.append(&mut kept.excerpts);
                    kept.excerpts = excerpts;
                });
                c.set_text_end(engine, &target, &prompt.text);
                kept::save(engine);
                let route = if drafts::draft(engine, &target).is_some() {
                    Route::Draft(target)
                } else {
                    Route::Thread(target)
                };
                controller::with::<Navigation, _>(engine, |n, e| n.open(e, route));
            });
        });
        sticky_error(engine, title, description, restore);
    }

    fn forget_unsent(&self, engine: &Engine, message_id: &str) {
        let removed = kept::write(engine, |d| {
            let before = d.unsent.len();
            d.unsent.retain(|u| u.message_id != message_id);
            d.unsent.len() != before
        });
        if removed {
            kept::save(engine);
        }
    }

    /// A send whose answer a drop took: reconciled against the shell as it
    /// is after the drop; a launch is asked again (`launch`).
    fn keep_unanswered(&self, engine: &Engine, message_id: &str, launch: Obj) {
        let seen = store::with(engine, |s| s.snapshots());
        let found = kept::write(engine, |d| {
            let unsent = d.unsent.iter_mut().find(|u| u.message_id == message_id)?;
            unsent.kept = true;
            unsent.seen = seen;
            unsent.launch = launch;
            Some(())
        });
        if found.is_some() {
            kept::save(engine);
        }
    }

    /// The MC may have taken the launch and not made its thread yet: asked
    /// again under its command id, it answers once, and only a refusal
    /// brings the prompt back (reconcile_unsent).
    fn retry_launch(&mut self, message_id: &str, engine: &Engine) {
        let found = kept::write(engine, |d| {
            let unsent = d.unsent.iter_mut().find(|u| u.message_id == message_id)?;
            unsent.kept = false;
            Some((std::mem::take(&mut unsent.launch), unsent.thread.clone()))
        });
        let Some((launch, thread)) = found else {
            return;
        };
        let environment_id = thread.split(':').next().unwrap_or_default().to_owned();
        let id = message_id.to_owned();
        self.mc.call(
            &environment_id,
            "orchestration.launchThread",
            Json::Object(launch.clone()),
            back(&self.me, move |c, engine, result| {
                if let Err(error) = &result
                    && unanswered(error)
                {
                    c.keep_unanswered(engine, &id, launch);
                    return;
                }
                let found = kept::write(engine, |d| {
                    let index = d.unsent.iter().position(|u| u.message_id == id)?;
                    if result.is_err() {
                        d.unsent[index].kept = true;
                    } else {
                        // A thread has the prompt, the draft becomes it
                        // (drafts' reconcile).
                        let batch = d.unsent[index].batch.clone();
                        d.unsent.retain(|u| {
                            u.message_id != id && (batch.is_empty() || u.batch != batch)
                        });
                    }
                    Some(())
                });
                if found.is_none() {
                    return;
                }
                kept::save(engine);
                c.reconcile_unsent(engine);
            }),
        );
    }

    /// The thread's newest user message ahead of the sends still on their
    /// way to it, once its messages are known.
    fn newest_before(&self, engine: &Engine, thread: &str) -> Option<String> {
        let (pending, delivered) = kept::read(engine, |d| {
            let pending: HashSet<String> = d
                .unsent
                .iter()
                .filter(|u| u.target == thread)
                .map(|u| u.message_id.clone())
                .collect();
            (
                pending,
                d.delivered.get(thread).cloned().unwrap_or_default(),
            )
        });
        self.timeline
            .and_then(|obj| {
                TimelineModel::read(engine, obj, |t| {
                    if t.thread_key() != thread || t.status() != "live" {
                        return None;
                    }
                    let messages = t.entities("message");
                    if !delivered.is_empty() && !messages.contains_key(&delivered) {
                        return Some(delivered);
                    }
                    Some(newest_user_message(messages, &pending))
                })
            })
            .flatten()
    }

    /// A kept send's fate shows once the thread's messages do: one the MC
    /// got is there and is dropped; one behind a newer user message
    /// (another device's, or this one's after the restart) is dropped too,
    /// as the user moved on. The rest come back to the draft: into it when
    /// it is empty, else behind a toast that restores them once it is. A new
    /// thread's first send waits for the shell to know whether the thread
    /// exists.
    pub(super) fn reconcile_unsent(&mut self, engine: &Engine) {
        let timeline = self.timeline.and_then(|obj| {
            TimelineModel::read(engine, obj, |t| {
                (t.thread_key().to_owned(), t.status() == "live")
            })
        });
        // A send made before its thread's messages were known measures from
        // when they are, so a newer message from elsewhere still drops it.
        if let Some((key, _)) = &timeline {
            let unmeasured = |u: &Unsent| !u.kept && u.after.is_none() && u.target == *key;
            if kept::read(engine, |d| d.unsent.iter().any(unmeasured))
                && let Some(newest) = self.newest_before(engine, key)
            {
                kept::write(engine, |d| {
                    for unsent in d.unsent.iter_mut().filter(|u| unmeasured(u)) {
                        unsent.after = Some(newest.clone());
                    }
                });
                kept::save(engine);
            }
        }
        let unsent: Vec<Unsent> = kept::read(engine, |d| {
            if d.unsent.iter().any(|u| u.kept) {
                d.unsent.clone()
            } else {
                Vec::new()
            }
        });
        if !self.active || unsent.is_empty() {
            return;
        }
        let (key, live) = timeline.unwrap_or_default();
        let messages: BTreeMap<String, Obj> = if live {
            self.read_timeline(engine, |t| t.entities("message").clone())
        } else {
            BTreeMap::new()
        };
        let mine: HashSet<String> = unsent
            .iter()
            .filter(|u| u.kept)
            .map(|u| u.message_id.clone())
            .collect();
        let newest = if live {
            newest_user_message(&messages, &mine)
        } else {
            String::new()
        };
        // Where each send's thread is now, whether the shell lists it, and
        // whether its machine is heard from.
        struct Seen {
            key: String,
            exists: bool,
            online: bool,
        }
        let (snapshots, seen): (u64, Vec<Seen>) = store::with(engine, |s| {
            let synchronized = s.synchronized();
            let seen = unsent
                .iter()
                .map(|u| {
                    let key = s.located(&u.thread);
                    let environment = key.split(':').next().unwrap_or_default();
                    Seen {
                        exists: s.thread(&key).is_some(),
                        online: synchronized && s.environment_online(environment),
                        key,
                    }
                })
                .collect();
            (s.snapshots(), seen)
        });
        // The sends to several models that started a thread, or have come
        // back; and those with a launch still to be answered, which may yet
        // start one.
        let mut started: HashSet<String> = HashSet::new();
        let mut waiting: HashSet<String> = HashSet::new();
        for (u, seen) in unsent.iter().zip(&seen) {
            if u.batch.is_empty() {
                continue;
            }
            if u.kept && seen.exists {
                started.insert(u.batch.clone());
            }
            if !u.kept || (!u.launch.is_empty() && !seen.exists) {
                waiting.insert(u.batch.clone());
            }
        }
        // What each target gets back, in the order the targets were sent to.
        let mut targets: Vec<String> = Vec::new();
        let mut restores: HashMap<String, Vec<&Unsent>> = HashMap::new();
        let mut settled: HashSet<String> = HashSet::new();
        let mut retries: Vec<String> = Vec::new();
        for (u, seen) in unsent.iter().zip(&seen) {
            // One whose answer a drop took waits for the shell as it is after
            // the drop.
            if !u.kept || snapshots <= u.seen {
                continue;
            }
            let mut into = String::new();
            if u.target != u.thread {
                // A launch: the thread it made, or the draft it came from.
                if !seen.online {
                    continue;
                }
                if !seen.exists && !u.launch.is_empty() {
                    retries.push(u.message_id.clone());
                    continue;
                }
                if !seen.exists && waiting.contains(&u.batch) && !started.contains(&u.batch) {
                    continue;
                }
                if !seen.exists
                    && drafts::draft(engine, &u.target).is_some()
                    && !started.contains(&u.batch)
                {
                    into = u.target.clone();
                }
                if !u.batch.is_empty() {
                    started.insert(u.batch.clone());
                }
            } else if seen.online && !seen.exists {
                // The thread is gone.
            } else if !live || key != seen.key {
                continue;
            } else if !messages.contains_key(&u.message_id)
                && u.after.as_ref().is_none_or(|after| *after == newest)
            {
                into = seen.key.clone();
            }
            settled.insert(u.message_id.clone());
            if into.is_empty() {
                continue;
            }
            if !restores.contains_key(&into) {
                targets.push(into.clone());
            }
            restores.entry(into).or_default().push(u);
        }
        for message_id in &retries {
            self.retry_launch(message_id, engine);
        }
        if settled.is_empty() {
            return;
        }
        kept::write(engine, |d| {
            d.unsent.retain(|u| !settled.contains(&u.message_id))
        });
        for target in &targets {
            let mut prompt = Prompt::default();
            let mut prompts = Vec::new();
            for u in restores.get(target).into_iter().flatten() {
                if !u.prompt.is_empty() {
                    prompts.push(u.prompt.clone());
                }
                prompt.attachments.extend(u.attachments.iter().cloned());
                prompt.excerpts.extend(u.excerpts.iter().cloned());
            }
            prompt.text = prompts.join("\n\n");
            let empty =
                kept::draft(engine, target).is_empty() && !kept::draft_of(engine, target).carries();
            if empty {
                kept::edit_draft(engine, target, |kept| {
                    kept.attachments = prompt.attachments;
                    kept.excerpts = prompt.excerpts;
                });
                self.set_text_end(engine, target, &prompt.text);
            } else {
                self.offer_restore(
                    engine,
                    target,
                    "A prompt was not sent",
                    "HAL-C2 closed before it was sent. Your newer draft is unchanged. Restore the prompt when this composer is empty.",
                    prompt,
                );
            }
        }
        kept::save(engine);
        self.publish(engine);
    }
}
