//! The composer's actions: the text and its suggestions, the history, the
//! picker's model and options, the modes, the stash, the thread's pending
//! requests and its queue.

use std::sync::LazyLock;

use ljos::prelude::Engine;
use regex::Regex;
use serde_json::json;

use super::kept::{self, QueuedEdit, StashEntry};
use super::state::options_of;
use super::text::{
    self, MAX_CITATION_LENGTH, MAX_STASH_ENTRIES, ULTRATHINK_PREFIX, items_of, left, recallable,
    stale_request,
};
use super::{
    Composer, Recall, back, find_attachment, now_iso, publish_everywhere, string, thread_of, toast,
    toast_error, uuid,
};
use crate::composer_model as model;
use crate::controller;
use crate::controllers::settings::Settings;
use crate::controllers::toasts::{DEFAULT_TIMEOUT_MS, Toasts};
use crate::controllers::workspace;
use crate::json::Json;
use crate::store;
use crate::thread_view::summary::{Obj, as_object, text as field};

static SLASH_MODE: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"(?i)^/(plan|default)\s*$").ok());
static SLASH_USAGE_LIMITS: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"(?i)^/usage-limits\s*$").ok());
static ULTRATHINK: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"(?i)^Ultrathink:\s*").ok());
static SLASH_COMMAND: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"^/[^\s/]+(?:\s|$)").ok());

fn matches(regex: &LazyLock<Option<Regex>>, text: &str) -> bool {
    regex.as_ref().is_some_and(|r| r.is_match(text))
}

impl Composer {
    pub(super) fn handle_action(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        let target = self.target(engine);
        let id = string(payload, "id");
        match action {
            "composer.text.set" => {
                // A target the window has left: its last keystrokes are
                // dropped.
                if target.is_empty() || string(payload, "target") != target {
                    return true;
                }
                let cursor = text::number(&payload["cursor"]) as i64;
                self.set_text(
                    engine,
                    &target,
                    &string(payload, "text"),
                    cursor,
                    payload.get("edit").unwrap_or(&Json::Null),
                );
            }
            "composer.suggest.select" => {
                if !target.is_empty() {
                    self.select_suggestion(engine, &target, &id);
                }
            }
            "composer.suggest.dismiss" => {
                if target.is_empty() {
                    return true;
                }
                kept::edit_draft(engine, &target, |kept| kept.dismissed = true);
                self.publish(engine);
            }
            "composer.history.step" => {
                if !target.is_empty() {
                    let backward = string(payload, "direction") != "forward";
                    self.step_history(engine, &target, backward);
                }
            }
            "composer.terminalContext.add" => return self.add_terminal_context(engine, payload),
            "composer.reviewComment.add" => return self.add_review_comment(engine, payload),
            "composer.citation.add" => return self.add_citation(engine, payload),
            "composer.citation.comment" => {
                if target.is_empty() {
                    return true;
                }
                // withAssistantCitationComment: a blank comment is no
                // comment.
                let comment =
                    left(string(payload, "comment").trim(), MAX_CITATION_LENGTH).to_owned();
                let found = kept::edit_draft(engine, &target, |kept| {
                    let excerpt = kept
                        .excerpts
                        .iter_mut()
                        .find(|e| e.id == id && !e.citation.is_empty())?;
                    if comment.is_empty() {
                        excerpt.citation.remove("comment");
                    } else {
                        excerpt.citation.insert("comment".into(), json!(comment));
                    }
                    Some(())
                });
                if found.is_some() {
                    self.publish(engine);
                }
            }
            "composer.terminalContext.remove"
            | "composer.citation.remove"
            | "composer.reviewComment.remove" => {
                if target.is_empty() {
                    return true;
                }
                let removed = kept::edit_draft(engine, &target, |kept| {
                    let before = kept.excerpts.len();
                    kept.excerpts.retain(|e| e.id != id);
                    kept.excerpts.len() != before
                });
                if removed {
                    self.publish(engine);
                }
            }
            "composer.model.select" => {
                if !target.is_empty() {
                    self.select_model(
                        engine,
                        &target,
                        &string(payload, "instanceId"),
                        &string(payload, "model"),
                    );
                }
            }
            "composer.model.multiple.toggle" => {
                if !target.is_empty() {
                    self.toggle_multiple_model(
                        engine,
                        &target,
                        &string(payload, "instanceId"),
                        &string(payload, "model"),
                    );
                }
            }
            "composer.model.favorite.toggle" => {
                let settings = Settings::of(engine);
                let favorites = model::toggle_favorite(
                    &settings.device_value("favorites").unwrap_or(Json::Null),
                    &string(payload, "instanceId"),
                    &string(payload, "model"),
                );
                settings.write_device(engine, "favorites", favorites);
            }
            "composer.usageLimits.dismiss" => {
                if self.usage_limits.remove(&target).is_some() {
                    self.publish(engine);
                }
            }
            "composer.option.set" => {
                if !target.is_empty() {
                    self.set_option(
                        engine,
                        &target,
                        &id,
                        payload.get("value").unwrap_or(&Json::Null),
                    );
                }
            }
            "composer.runtimeMode.set" => {
                if target.is_empty() {
                    return true;
                }
                let mode = string(payload, "mode");
                let selection = self.selection(engine, &target);
                let known = model::runtime_modes(self.instance_of(&selection))
                    .iter()
                    .any(|entry| entry["value"] == mode.as_str());
                if !known || mode == self.runtime_mode_of(engine, &target) {
                    return true;
                }
                kept::edit_draft(engine, &target, |kept| kept.runtime_mode = mode);
                kept::save(engine);
                self.publish(engine);
            }
            "composer.interactionMode.set" => {
                if !target.is_empty() {
                    self.set_interaction_mode(engine, &target, &string(payload, "mode"));
                }
            }
            "composer.stash" => return self.stash(engine, &target),
            "composer.stash.restore" => {
                if !target.is_empty() {
                    self.restore_stash(engine, &target, &id);
                }
            }
            "composer.stash.delete" => {
                let removed = kept::write(engine, |d| {
                    let before = d.stash.len();
                    d.stash.retain(|entry| entry.id != id);
                    (d.stash.len() != before).then_some(d.stash.is_empty())
                });
                let Some(empty) = removed else {
                    return true;
                };
                if empty {
                    self.stash_open = false;
                }
                kept::save(engine);
                self.publish(engine);
            }
            "composer.stash.menu" => {
                let open = payload
                    .get("open")
                    .and_then(Json::as_bool)
                    .unwrap_or(!self.stash_open);
                self.set_stash_open(engine, open);
            }
            "composer.interrupt" => return self.interrupt(engine),
            "composer.submit" => return self.submit(engine, payload),
            "composer.attach" => {
                if target.is_empty() {
                    return true;
                }
                let folders = list(payload, "folders");
                if !folders.is_empty() {
                    self.attach_folders(engine, &target, &folders);
                }
                let files = list(payload, "files");
                if files.is_empty() {
                    return true;
                }
                // While the agent waits on an answer, files are the answer's.
                let turn = self.turn_state(engine);
                if let Some(first) = turn["questions"].as_array().and_then(|q| q.first()) {
                    let request_id = first["requestId"].as_str().unwrap_or_default().to_owned();
                    return self.attach_to_answer(engine, &request_id, "", &files);
                }
                return self.attach(engine, &files);
            }
            "composer.question.attach" => {
                return self.attach_to_answer(
                    engine,
                    &string(payload, "requestId"),
                    &string(payload, "questionId"),
                    &list(payload, "files"),
                );
            }
            "composer.attachment.remove" | "composer.question.attachment.remove" => {
                let Some(found) = find_attachment(engine, &id) else {
                    return true;
                };
                // An upload no message took is the MC's to drop.
                if !found.remote_id.is_empty() {
                    self.mc.call(
                        &found.environment_id,
                        "attachments.delete",
                        json!({"attachmentId": found.remote_id}),
                        Box::new(|_, _| {}),
                    );
                }
                kept::write(engine, |d| {
                    for kept in d.drafts.values_mut() {
                        kept.attachments.retain(|a| a.id != id);
                    }
                    for questions in d.answer_files.values_mut() {
                        for files in questions.values_mut() {
                            files.retain(|a| a.id != id);
                        }
                    }
                });
                kept::save(engine);
                self.publish(engine);
            }
            "composer.attachment.retry" => {
                if let Some(found) = find_attachment(engine, &id)
                    && found.file
                    && found.upload == "failed"
                {
                    let environment_id = if found.environment_id.is_empty() {
                        self.environment_of(engine, &self.thread.clone())
                    } else {
                        found.environment_id
                    };
                    self.upload_file(engine, &id, &environment_id);
                }
            }
            "composer.approval.respond" => {
                let mut fields = Obj::new();
                fields.insert("decision".into(), json!(string(payload, "decision")));
                return self.respond(
                    engine,
                    &string(payload, "requestId"),
                    fields,
                    "Failed to submit approval decision.",
                );
            }
            "composer.question.answer" => {
                let request_id = string(payload, "requestId");
                let mut fields = Obj::new();
                fields.insert(
                    "answers".into(),
                    Json::Object(as_object(&payload["answers"]).clone()),
                );
                let attached = kept::read(engine, |d| {
                    d.answer_files.get(&request_id).cloned().unwrap_or_default()
                });
                let mut files = Obj::new();
                for (question, list) in &attached {
                    if list.is_empty() {
                        continue;
                    }
                    if self.files_block(engine, list, "answering") {
                        return true;
                    }
                    files.insert(
                        question.clone(),
                        Json::Array(super::attachments::file_records(list)),
                    );
                }
                if !files.is_empty() {
                    fields.insert("attachmentsByQuestionId".into(), Json::Object(files));
                }
                return self.respond(engine, &request_id, fields, "Failed to submit answers.");
            }
            "composer.question.dismiss" => {
                return self.respond(
                    engine,
                    &string(payload, "requestId"),
                    Obj::new(),
                    "Failed to dismiss the question.",
                );
            }
            "composer.plan.implement" => {
                if thread_of(engine, &target).is_none() {
                    return true;
                }
                return self.send_turn(engine, &target, "", "auto", true, false);
            }
            "composer.queue.remove" => {
                return self.queue_command(engine, "queued-run.cancel", &string(payload, "runId"));
            }
            "composer.queue.edit" => {
                return self.edit_queued(engine, &target, &string(payload, "runId"));
            }
            "composer.queue.edit.cancel" => {
                let editing = kept::read(engine, |d| {
                    d.queued_edit.as_ref().is_some_and(|e| e.thread == target)
                });
                if editing {
                    self.end_queued_edit(engine, false);
                }
            }
            "composer.queue.resume" => return self.resume_queue(engine),
            "composer.queue.steer" => {
                // Without a run, the first queued one (the steer key).
                let mut run_id = string(payload, "runId");
                if run_id.is_empty() {
                    let turn = self.turn_state(engine);
                    run_id = turn["queue"][0]["runId"]
                        .as_str()
                        .unwrap_or_default()
                        .to_owned();
                }
                return self.queue_command(engine, "queued-message.promote-to-steer", &run_id);
            }
            _ => return false,
        }
        true
    }

    /// Up and Down on an empty composer bring back the thread's sent
    /// prompts, newest first.
    fn step_history(&mut self, engine: &Engine, target: &str, backward: bool) {
        if self.timeline.is_none() || target != self.thread {
            return;
        }
        let kept = kept::draft_of(engine, target);
        let current = kept::draft(engine, target);
        // Oldest first; a prompt sent twice in a row is one entry, its newest.
        let entries: Vec<(String, String)> = self.read_timeline(engine, |t| {
            let mut entries: Vec<(String, String)> = Vec::new();
            for item in items_of(t.entities("turn-item"), "user_message") {
                let prompt = recallable(field(item, "text"));
                if prompt.is_empty() {
                    continue;
                }
                if entries.last().is_some_and(|(_, last)| *last == prompt) {
                    entries.pop();
                }
                entries.push((field(item, "id").to_owned(), prompt));
            }
            entries
        });
        let mut active: Option<usize> = None;
        if let Some(recall) = &self.recall
            && recall.target == target
            && recall.recalled == current
        {
            active = entries.iter().rposition(|(id, _)| *id == recall.entry_id);
            if active.is_none() {
                active = entries.iter().rposition(|(_, prompt)| *prompt == current);
            }
        }
        let next = if backward {
            // Only an empty composer starts a recall: attachments count as
            // content.
            if active.is_none() && (!current.is_empty() || kept.carries()) {
                return;
            }
            match active {
                None if entries.is_empty() => return,
                None => entries.len() - 1,
                Some(0) => return,
                Some(i) => i - 1,
            }
        } else {
            match active {
                None => return,
                Some(i) => i + 1,
            }
        };
        let Some((entry_id, prompt)) = entries.get(next).cloned() else {
            self.recall = None;
            self.set_text_end(engine, target, "");
            return;
        };
        self.recall = Some(Recall {
            target: target.to_owned(),
            entry_id,
            recalled: prompt.clone(),
        });
        self.set_text_end(engine, target, &prompt);
    }

    /// The draft goes to the stash and the composer empties; an empty draft
    /// brings back the only entry, or opens the list. Nothing while an
    /// approval waits; a question waiting opens the list instead.
    fn stash(&mut self, engine: &Engine, target: &str) -> bool {
        if target.is_empty() {
            return true;
        }
        let turn = self.turn_state(engine);
        if turn["approvals"].as_array().is_some_and(|a| !a.is_empty()) {
            return true;
        }
        if turn["questions"].as_array().is_some_and(|q| !q.is_empty()) {
            self.set_stash_open(engine, !self.stash_open);
            return true;
        }
        let kept = kept::draft_of(engine, target);
        if kept.attachments.iter().any(|a| a.upload == "uploading") {
            toast(
                engine,
                "warning",
                "Wait for file uploads before stashing this prompt",
                "",
            );
            return true;
        }
        let text = kept::draft(engine, target).trim().to_owned();
        if text.is_empty() && !kept.carries() {
            let only = kept::read(engine, |d| {
                (d.stash.len() == 1).then(|| d.stash[0].id.clone())
            });
            match only {
                Some(id) => self.restore_stash(engine, target, &id),
                None => self.set_stash_open(engine, !self.stash_open),
            }
            return true;
        }
        let entry = StashEntry {
            id: uuid(),
            created_at: now_iso(engine),
            text,
            attachments: kept.attachments,
            excerpts: kept.excerpts,
        };
        let dropped = kept::write(engine, |d| {
            d.stash.insert(0, entry);
            let over = d.stash.len() > MAX_STASH_ENTRIES;
            if over {
                d.stash.pop();
            }
            over
        });
        if dropped {
            toast(
                engine,
                "warning",
                "Oldest stashed prompt discarded",
                &format!(
                    "The stash holds {MAX_STASH_ENTRIES} prompts; the oldest was removed to make room."
                ),
            );
        }
        kept::edit_draft(engine, target, |kept| {
            kept.attachments.clear();
            kept.excerpts.clear();
        });
        // Clearing publishes.
        self.set_text_end(engine, target, "");
        kept::save(engine);
        true
    }

    /// The entry joins what the draft already holds, after a blank line,
    /// and leaves the stash.
    fn restore_stash(&mut self, engine: &Engine, target: &str, id: &str) {
        let entry = kept::write(engine, |d| {
            let index = d.stash.iter().position(|e| e.id == id)?;
            Some(d.stash.remove(index))
        });
        let Some(entry) = entry else {
            return;
        };
        self.stash_open = false;
        kept::edit_draft(engine, target, |kept| {
            kept.attachments.extend(entry.attachments);
            kept.excerpts.extend(entry.excerpts);
        });
        let current = kept::draft(engine, target);
        let text = if current.trim().is_empty() {
            entry.text
        } else {
            format!("{}\n\n{}", current.trim(), entry.text)
        };
        self.set_text_end(engine, target, &text);
        kept::save(engine);
    }

    fn set_stash_open(&mut self, engine: &Engine, open: bool) {
        if open == self.stash_open {
            return;
        }
        self.stash_open = open;
        self.publish(engine);
    }

    /// Answers an approval or a question (`fields` empty dismisses it).
    fn respond(&mut self, engine: &Engine, request_id: &str, fields: Obj, failure: &str) -> bool {
        let Some(thread) = thread_of(engine, &self.thread) else {
            return true;
        };
        if request_id.is_empty() || self.responding.contains(request_id) {
            return true;
        }
        let mut command = Obj::new();
        command.insert(
            "type".into(),
            json!(if fields.is_empty() {
                "thread.user-input.dismiss"
            } else {
                "runtime-request.respond"
            }),
        );
        command.insert("threadId".into(), json!(thread.id));
        command.insert("requestId".into(), json!(request_id));
        command.extend(fields);
        self.responding.insert(request_id.to_owned());
        self.publish(engine);
        let request_id = request_id.to_owned();
        let failure = failure.to_owned();
        self.mc.dispatch_command(
            &thread.environment_id,
            Json::Object(command),
            back(&self.me, move |c, engine, result| {
                c.responding.remove(&request_id);
                match result {
                    Ok(_) => {
                        kept::write(engine, |d| d.answer_files.remove(&request_id));
                    }
                    Err(error) if stale_request(&error.message) => {
                        c.closed.insert(request_id);
                    }
                    Err(error) => toast_error(engine, &failure, &error.message),
                }
                c.publish(engine);
            }),
        );
        true
    }

    /// Removes a queued message, or makes it steer the running turn.
    fn queue_command(&mut self, engine: &Engine, kind: &str, run_id: &str) -> bool {
        let Some(thread) = thread_of(engine, &self.thread) else {
            return true;
        };
        if run_id.is_empty() {
            return true;
        }
        let cancel = kind == "queued-run.cancel";
        let mut command = json!({"type": kind, "threadId": thread.id});
        if cancel {
            command["runId"] = json!(run_id);
        } else {
            let Some(active) = &thread.active_run_id else {
                return true;
            };
            command["queuedRunId"] = json!(run_id);
            command["targetRunId"] = json!(active);
        }
        let failure = if cancel {
            "Failed to remove the queued message."
        } else {
            "Failed to steer with the queued message."
        };
        self.mc.dispatch_command(
            &thread.environment_id,
            command,
            back(&self.me, move |_, engine, result| {
                if let Err(error) = result {
                    toast_error(engine, failure, &error.message);
                }
            }),
        );
        true
    }

    /// Lets the MC start a queue it holds (after a restart or a usage
    /// limit). One request at a time per thread across every window, and
    /// only for a queue still held: a click on a stale card, after another
    /// device resumed it, asks nothing. The thread's stream has to be caught
    /// up too: the held flag a reconnected window still shows may be one the
    /// MC has since cleared. The answer is handled apart from this window,
    /// which may close before it comes: a refusal is told in the window that
    /// asked, else in the one in front.
    fn resume_queue(&mut self, engine: &Engine) -> bool {
        let Some(thread) = thread_of(engine, &self.thread) else {
            return true;
        };
        let key = self.thread.clone();
        if kept::read(engine, |d| d.resuming.contains(&key)) || !self.queue_held(engine) {
            return true;
        }
        let live = self.read_timeline(engine, |t| t.thread_key() == key && t.status() == "live");
        let connected = self.mc.is_ready()
            && store::with(engine, |s| s.synchronized() && s.thread_online(&key));
        if !connected || !live {
            // One warning however often the button is pressed while
            // reconnecting: a toast still showing is renewed rather than
            // stacked.
            let title = "Not connected: queue not resumed";
            let description = "Reconnecting to the environment. Try again once it is connected.";
            let shown = self.not_connected_toast.clone();
            let id = controller::with::<Toasts, _>(engine, |t, e| {
                if !shown.is_empty()
                    && t.replace(e, &shown, "warning", title, description, Vec::new(), 5000)
                {
                    return shown;
                }
                t.show(e, "warning", title, description, None, DEFAULT_TIMEOUT_MS)
            });
            if let Some(id) = id {
                self.not_connected_toast = id;
            }
            return true;
        }
        // The shared MC, not this window's: the answer has to clear
        // `resuming` even when this window has closed. It comes as the
        // window that asked while that is open, else as the one in front.
        let Some(mc) = controller::mc(engine) else {
            return true;
        };
        kept::write(engine, |d| d.resuming.insert(key.clone()));
        mc.dispatch_command(
            &thread.environment_id,
            json!({"type": "queue.resume", "threadId": thread.id}),
            Box::new(move |engine, result| {
                // Cleared by the answer alone, not by the held flag clearing
                // on the stream: the answer may come first, and until the
                // event follows, the button is enabled for a queue still
                // shown as held. A click then asks again, which is harmless:
                // `queue.resume` only clears the flag and starts the next run
                // if none is active. Holding `resuming` until the flag clears
                // would instead leave "Resuming…" stuck whenever the queue is
                // held again at once (the next run hitting the same usage
                // limit).
                kept::write(engine, |d| d.resuming.remove(&key));
                if let Err(error) = result {
                    toast_error(engine, "Failed to resume the queue.", &error.message);
                }
                publish_everywhere(engine);
            }),
        );
        // This window greys the button now, so a second click cannot ask
        // again; the others follow once the composer returns.
        self.publish(engine);
        publish_everywhere(engine);
        true
    }

    /// The composer edits a queued message (the last without `run_id`); the
    /// thread's draft waits aside until the edit ends.
    fn edit_queued(&mut self, engine: &Engine, target: &str, run_id: &str) -> bool {
        let saving = kept::read(engine, |d| d.queued_edit.as_ref().is_some_and(|e| e.saving));
        if target.is_empty() || !self.draft_id.is_empty() || saving {
            return true;
        }
        let turn = self.turn_state(engine);
        let queue = turn["queue"].as_array().cloned().unwrap_or_default();
        let Some(last) = queue.last() else {
            return true;
        };
        let run_id = if run_id.is_empty() {
            last["runId"].as_str().unwrap_or_default().to_owned()
        } else {
            run_id.to_owned()
        };
        let Some(entry) = queue.iter().find(|item| item["runId"] == run_id.as_str()) else {
            return true;
        };
        let text = entry["text"].as_str().unwrap_or_default().to_owned();
        let saved = kept::draft(engine, target);
        let saved_cursor = kept::read(engine, |d| d.drafts.get(target).map_or(0, |k| k.cursor));
        kept::write(engine, |d| {
            // Moving to another queued message keeps the draft set aside for
            // the first.
            let edit = match d.queued_edit.take() {
                Some(edit) if edit.thread == target => edit,
                _ => QueuedEdit {
                    thread: target.to_owned(),
                    saved,
                    saved_cursor,
                    ..QueuedEdit::default()
                },
            };
            d.queued_edit = Some(QueuedEdit {
                run_id,
                original: text.clone(),
                ..edit
            });
        });
        self.set_text_end(engine, target, &text);
        true
    }

    pub(super) fn save_queued_edit(&mut self, engine: &Engine, target: &str, text: &str) -> bool {
        let Some(thread) = thread_of(engine, target) else {
            return true;
        };
        let run_id = kept::write(engine, |d| {
            let edit = d.queued_edit.as_mut()?;
            if edit.saving || text.trim().is_empty() {
                return None;
            }
            edit.saving = true;
            Some(edit.run_id.clone())
        });
        let Some(run_id) = run_id else {
            return true;
        };
        let command = json!({
            "type": "queued-run.edit",
            "threadId": thread.id,
            "runId": run_id,
            "text": text.trim(),
        });
        self.mc.dispatch_command(
            &thread.environment_id,
            command,
            back(&self.me, move |c, engine, result| {
                let current = kept::write(engine, |d| match d.queued_edit.as_mut() {
                    Some(edit) if edit.run_id == run_id => {
                        edit.saving = false;
                        true
                    }
                    _ => false,
                });
                if !current {
                    return;
                }
                if let Err(error) = result {
                    toast_error(
                        engine,
                        "Could not save the edited queued message.",
                        &error.message,
                    );
                    c.publish(engine);
                    return;
                }
                c.end_queued_edit(engine, false);
            }),
        );
        self.publish(engine);
        true
    }

    /// The edit ends: the thread's draft comes back, unless `keep` leaves
    /// the edit as the draft.
    pub(super) fn end_queued_edit(&mut self, engine: &Engine, keep: bool) {
        let Some(edit) = kept::write(engine, |d| d.queued_edit.take()) else {
            return;
        };
        if keep {
            kept::save(engine);
            self.publish(engine);
            return;
        }
        self.set_text(
            engine,
            &edit.thread,
            &edit.saved,
            edit.saved_cursor,
            &Json::Null,
        );
    }

    /// The message being edited left the queue (it ran, or another device
    /// removed it): the edit ends, kept if it is all the draft holds.
    pub(super) fn recover_queued_edit(&mut self, engine: &Engine, turn: &Json) {
        let Some(edit) = kept::read(engine, |d| d.queued_edit.clone()) else {
            return;
        };
        if edit.saving || edit.thread != self.thread || self.timeline.is_none() {
            return;
        }
        let queued = turn["queue"]
            .as_array()
            .into_iter()
            .flatten()
            .any(|item| item["runId"] == edit.run_id.as_str());
        if queued {
            return;
        }
        let dirty = kept::draft(engine, &edit.thread) != edit.original;
        let keep = dirty && edit.saved.trim().is_empty();
        self.end_queued_edit(engine, keep);
        if !dirty {
            return;
        }
        toast(
            engine,
            if keep { "info" } else { "warning" },
            "Queued message is no longer queued",
            if keep {
                "Your unsaved edit was kept in the composer."
            } else {
                "Your unsaved edit was discarded."
            },
        );
    }

    /// A standalone "/plan" or "/default" only switches the mode.
    pub(super) fn slash_mode(&mut self, engine: &Engine, target: &str, text: &str) -> bool {
        let trimmed = text.trim();
        if !matches(&SLASH_MODE, trimmed)
            || kept::draft_of(engine, target).carries()
            || !self.plan_on_for(engine, target)
        {
            return false;
        }
        let mode = trimmed[1..].trim().to_lowercase();
        self.set_interaction_mode(engine, target, &mode);
        self.set_text_end(engine, target, "");
        true
    }

    /// "/usage-limits" shows the provider's limits above the composer.
    pub(super) fn slash_usage_limits(&mut self, engine: &Engine, target: &str, text: &str) -> bool {
        if !matches(&SLASH_USAGE_LIMITS, text.trim()) {
            return false;
        }
        let selection = self.selection(engine, target);
        // Offered by the environment only where there are limits to show.
        let Some(instance) = self.instance_of(&selection).filter(|i| {
            i.slash_commands
                .iter()
                .any(|command| command["name"] == "usage-limits")
        }) else {
            return false;
        };
        let windows: Vec<Json> = instance
            .usage_limits
            .get("windows")
            .and_then(Json::as_array)
            .into_iter()
            .flatten()
            .map(|window| {
                let used = window["usedPercent"].as_f64().unwrap_or(0.0);
                json!({
                    "label": window["label"].as_str().unwrap_or_default(),
                    "usedPercent": used,
                    "remainingPercent": (100.0 - used).clamp(0.0, 100.0),
                    "resetsAt": window["resetsAt"].as_str().unwrap_or_default(),
                })
            })
            .collect();
        let message = if windows.is_empty() {
            format!("{} has not reported its limits yet.", instance.display_name)
        } else {
            String::new()
        };
        let limits = json!({
            "provider": instance.display_name,
            "checkedAt": field(&instance.usage_limits, "checkedAt"),
            "windows": windows,
            "message": message,
        });
        self.usage_limits.insert(target.to_owned(), limits);
        self.set_text_end(engine, target, "");
        self.publish(engine);
        true
    }

    fn set_interaction_mode(&mut self, engine: &Engine, target: &str, mode: &str) {
        if mode != "plan" && mode != "default" {
            return;
        }
        if mode == "plan" && !self.plan_on_for(engine, target) {
            return;
        }
        if mode == self.interaction_mode_of(engine, target) {
            return;
        }
        kept::edit_draft(engine, target, |kept| {
            kept.interaction_mode = mode.to_owned()
        });
        kept::save(engine);
        self.publish(engine);
    }

    /// A new thread starts from the model last sent with.
    pub(super) fn remember_model(&self, engine: &Engine, selection: &Obj) {
        let instance_id = field(selection, "instanceId");
        if instance_id.is_empty() {
            return;
        }
        kept::write(engine, |d| {
            if d.last_instance == instance_id && d.last_models.get(instance_id) == Some(selection) {
                return;
            }
            d.last_instance = instance_id.to_owned();
            d.last_models
                .insert(instance_id.to_owned(), selection.clone());
        });
    }

    /// A model its session cannot switch to says why instead; another
    /// provider takes the thread over on the next send.
    fn select_model(
        &mut self,
        engine: &Engine,
        target: &str,
        instance_id: &str,
        chosen_model: &str,
    ) -> bool {
        if instance_id.is_empty() || chosen_model.is_empty() {
            return false;
        }
        // Only what the picker offers: a ready provider's own models.
        let Some(next) = model::find(&self.catalogue, instance_id) else {
            return false;
        };
        if !next.ready() || model::find_model(next, chosen_model).is_empty() {
            return false;
        }
        if let Some(thread) = thread_of(engine, target)
            && thread.runtime.is_some()
        {
            let current = &thread.model_selection;
            if let Some(block) = model::block_reason(
                &self.catalogue,
                field(current, "instanceId"),
                field(current, "model"),
                instance_id,
                chosen_model,
            ) {
                toast(engine, "warning", &block.title, &block.description);
                return false;
            }
        }
        let current = self.selection(engine, target);
        let mut chosen = Obj::new();
        chosen.insert("instanceId".into(), json!(instance_id));
        chosen.insert("model".into(), json!(chosen_model));
        // Options belong to the provider they were set on.
        if field(&current, "instanceId") == instance_id
            && let Some(options) = current.get("options")
        {
            chosen.insert("options".into(), options.clone());
        }
        kept::edit_draft(engine, target, |kept| {
            kept.model_selection = Some(chosen);
            kept.multiple_models = None;
        });
        kept::save(engine);
        self.publish(engine);
        true
    }

    /// A started thread, or a model with one sibling, is one model's; a new
    /// thread's draft may name several.
    fn toggle_multiple_model(
        &mut self,
        engine: &Engine,
        target: &str,
        instance_id: &str,
        chosen_model: &str,
    ) -> bool {
        if self.draft_id.is_empty() || target != self.draft_id {
            return false;
        }
        let Some(instance) = model::find(&self.catalogue, instance_id) else {
            return false;
        };
        if !instance.ready() || model::find_model(instance, chosen_model).is_empty() {
            return false;
        }
        // Each model needs a worktree of its own: a folder that is not a Git
        // repository runs one model, the one just chosen.
        let not_repo = workspace::git(engine).is_some_and(|git| {
            !git.local
                .get("isRepo")
                .and_then(Json::as_bool)
                .unwrap_or(true)
        });
        if not_repo {
            toast(
                engine,
                "warning",
                "Only one model can be chosen",
                "Multiple models need a new thread in a Git project. Each gets its own worktree.",
            );
            kept::edit_draft(engine, target, |kept| kept.multiple_models = None);
            return self.select_model(engine, target, instance_id, chosen_model);
        }
        let selection = self.selection(engine, target);
        let (models, was_multiple) = kept::read(engine, |d| {
            let multiple = d.drafts.get(target).and_then(|k| k.multiple_models.clone());
            let was = multiple.is_some();
            (multiple.unwrap_or_else(|| vec![selection]), was)
        });
        let same = |chosen: &Obj| {
            field(chosen, "instanceId") == instance_id && field(chosen, "model") == chosen_model
        };
        let mut models = models;
        let before = models.len();
        models.retain(|chosen| !same(chosen));
        if models.len() == before {
            let mut added = Obj::new();
            added.insert("instanceId".into(), json!(instance_id));
            added.insert("model".into(), json!(chosen_model));
            models.push(added);
        }
        if models.len() <= 1 {
            // One model left is the draft's model again.
            kept::edit_draft(engine, target, |kept| {
                if let Some(first) = models.into_iter().next() {
                    kept.model_selection = Some(first);
                }
                kept.multiple_models = None;
            });
        } else {
            // Each model's thread starts in a worktree of its own.
            if !was_multiple {
                self.bridge
                    .dispatch(engine, "workspace.envMode.set", json!({"mode": "worktree"}));
            }
            kept::edit_draft(engine, target, |kept| kept.multiple_models = Some(models));
        }
        kept::save(engine);
        self.publish(engine);
        true
    }

    /// A choice the provider takes from the prompt (Claude's ultrathink) is
    /// put there instead; any other choice takes it out.
    fn set_option(&mut self, engine: &Engine, target: &str, id: &str, value: &Json) -> bool {
        let mut chosen = self.selection(engine, target);
        let Some(instance) = self.instance_of(&chosen) else {
            return false;
        };
        if !instance.ready() {
            return false;
        }
        let descriptors = model::descriptors(
            &model::find_model(instance, field(&chosen, "model")),
            &options_of(&chosen),
            self.plan_mode_on(engine, Some(instance)),
        );
        for descriptor in &descriptors {
            let injected = descriptor["promptInjectedValues"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            if descriptor["id"] != id || injected.is_empty() {
                continue;
            }
            let text = kept::draft(engine, target).trim().to_owned();
            if injected.contains(value) {
                if !text.starts_with(ULTRATHINK_PREFIX.trim()) && !matches(&SLASH_COMMAND, &text) {
                    self.set_text_end(engine, target, &format!("{ULTRATHINK_PREFIX}{text}"));
                }
                return true;
            }
            if let Some(prefix) = ULTRATHINK.as_ref()
                && prefix.is_match(&text)
            {
                let next = prefix.replace(&text, "").into_owned();
                self.set_text_end(engine, target, &next);
            }
        }
        let Some(options) = model::apply_option(&descriptors, id, value) else {
            return false;
        };
        chosen.insert("options".into(), Json::Array(options));
        kept::edit_draft(engine, target, |kept| kept.model_selection = Some(chosen));
        kept::save(engine);
        self.publish(engine);
        true
    }

    /// Puts the suggestion in the trigger's place; the composer's own
    /// commands act instead.
    fn select_suggestion(&mut self, engine: &Engine, target: &str, id: &str) -> bool {
        let text = kept::draft(engine, target);
        let kept = kept::draft_of(engine, target);
        let Some(trigger) = model::trigger(&text, kept.cursor) else {
            return false;
        };
        if kept.dismissed {
            return false;
        }
        let offered = self.suggestions(engine, target, Some(&trigger));
        let Some(chosen) = offered.into_iter().find(|item| item.id == id) else {
            return false;
        };
        let replacement = chosen.replacement;
        let length = model::utf16_len(&text);
        let mut end = trigger.end;
        if replacement.ends_with(' ') && end < length && model::slice(&text, end, end + 1) == " " {
            end += 1;
        }
        let next = format!(
            "{}{}{}",
            model::slice(&text, 0, trigger.start),
            replacement,
            model::slice(&text, end, length)
        );
        let cursor = (trigger.start + model::utf16_len(&replacement)) as i64;
        self.set_text(engine, target, &next, cursor, &Json::Null);
        if id == "slash:model" {
            self.bridge
                .send_to_bricks(engine, "composer.modelPicker.toggle", &Json::Null);
        } else if id == "slash:plan" || id == "slash:default" {
            self.set_interaction_mode(engine, target, &id[6..]);
        }
        true
    }
}

/// A payload's list field.
fn list(payload: &Json, key: &str) -> Vec<Json> {
    payload
        .get(key)
        .and_then(Json::as_array)
        .cloned()
        .unwrap_or_default()
}
