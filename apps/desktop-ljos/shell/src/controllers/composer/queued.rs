//! The queue's actions and the edit of a queued message: desktop-qt's
//! ComposerController queueCommand, editQueued, saveQueuedEdit,
//! endQueuedEdit and recoverQueuedEdits. An edit belongs to its thread and
//! outlives leaving it; it ends when it is saved, cancelled, or its message
//! leaves the queue.

use ljos::prelude::Engine;
use serde_json::json;

use super::attachments::{file_records, image_records};
use super::kept::{self, Attachment, QueuedEdit};
use super::{Composer, back, later, thread_of, toast, toast_error};
use crate::controllers::threads;
use crate::json::Json;
use crate::store;
use crate::thread_view::summary::text as field;
use crate::thread_view::timeline_model::TimelineModel;

const SAVE_FAILED: &str = "Could not save the edited queued message.";

fn string(value: &Json, key: &str) -> String {
    value[key].as_str().unwrap_or_default().to_owned()
}

/// The message keeps its attachments, then the added ones in the order
/// added.
fn with_attachments(
    engine: &Engine,
    target: &str,
    added: &[Attachment],
    mut command: Json,
) -> Json {
    let attachments = kept::read(engine, |d| {
        let Some(edit) = d.queued_edits.get(target) else {
            return Vec::new();
        };
        let mut attachments = edit.sent.clone();
        for attachment in added {
            if attachment.file {
                attachments.extend(file_records(std::slice::from_ref(attachment)));
            } else if let Some(stored) = edit.stored.get(&attachment.id) {
                attachments.push(stored.clone());
            }
        }
        attachments
    });
    command["attachments"] = Json::Array(attachments);
    command
}

impl Composer {
    /// Removes a queued message, or sends it now: a steer of the running
    /// turn, or on a stopped thread its own turn, ahead of the rest
    /// (`queued-run.start`). One queue action at a time per thread: the
    /// queue's buttons wait for the MC's answer (`turn.queueBusy`).
    pub(super) fn queue_command(&mut self, engine: &Engine, kind: &str, run_id: &str) -> bool {
        let Some(thread) = thread_of(engine, &self.thread) else {
            return true;
        };
        if run_id.is_empty() || self.queue_busy.contains(&self.thread) {
            return true;
        }
        let mut command = json!({"type": kind, "threadId": thread.id});
        let failure = if kind == "queued-run.cancel" {
            command["runId"] = json!(run_id);
            "Failed to remove the queued message."
        } else if let Some(active) = &thread.active_run_id {
            command["queuedRunId"] = json!(run_id);
            command["targetRunId"] = json!(active);
            "Failed to steer with the queued message."
        } else {
            command["type"] = json!("queued-run.start");
            command["runId"] = json!(run_id);
            "Failed to send the queued message."
        };
        let key = self.thread.clone();
        self.queue_busy.insert(key.clone());
        self.mc.dispatch_command(
            &thread.environment_id,
            command,
            back(&self.me, move |c, engine, result| {
                c.queue_busy.remove(&key);
                if let Err(error) = result {
                    toast_error(engine, failure, &error.message);
                }
                c.publish(engine);
            }),
        );
        self.publish(engine);
        true
    }

    /// The composer edits a queued message (the newest the MC has without
    /// `run_id`); the thread's draft and its attachments wait aside until
    /// the edit ends.
    pub(super) fn edit_queued(&mut self, engine: &Engine, target: &str, run_id: &str) -> bool {
        let open = kept::read(engine, |d| {
            d.queued_edits
                .get(target)
                .map(|e| (e.saving, e.run_id.clone()))
        });
        if target.is_empty()
            || !self.draft_id.is_empty()
            || open.as_ref().is_some_and(|(saving, _)| *saving)
            || self.queue_busy.contains(target)
        {
            return true;
        }
        let turn = self.turn_state(engine);
        // The question takes the composer: the queue cannot have it too.
        if !string(&turn, "queueEditBlocked").is_empty() {
            return true;
        }
        let queue = turn["queue"].as_array().cloned().unwrap_or_default();
        // The newest the MC has: one still being saved has no run to edit.
        let run_id = if run_id.is_empty() {
            queue
                .iter()
                .rev()
                .map(|item| string(item, "runId"))
                .find(|id| !id.is_empty())
                .unwrap_or_default()
        } else {
            run_id.to_owned()
        };
        if run_id.is_empty() {
            return true;
        }
        let Some(entry) = queue.iter().find(|item| item["runId"] == run_id.as_str()) else {
            return true;
        };
        let text = string(entry, "text");
        let message_id = string(entry, "messageId");
        let sent = self.read_timeline(engine, |t| {
            t.entities("message")
                .get(&message_id)
                .and_then(|m| m.get("attachments"))
                .and_then(Json::as_array)
                .cloned()
                .unwrap_or_default()
        });
        let saved = kept::draft(engine, target);
        kept::write(engine, |d| {
            let cursor = d.drafts.get(target).map_or(0, |k| k.cursor);
            // Moving to another queued message keeps the draft set aside
            // for the first; what was added for the one left goes aside
            // with it.
            let moving = open.as_ref().is_none_or(|(_, open)| *open != run_id);
            let taken = match d.drafts.get_mut(target) {
                Some(draft) if moving => std::mem::take(&mut draft.attachments),
                _ => Vec::new(),
            };
            let edit = d
                .queued_edits
                .entry(target.to_owned())
                .or_insert_with(|| QueuedEdit {
                    thread: target.to_owned(),
                    saved,
                    saved_cursor: cursor,
                    ..QueuedEdit::default()
                });
            if moving {
                edit.stored.clear();
            }
            edit.saved_attachments.extend(taken);
            edit.run_id = run_id;
            edit.message_id = message_id;
            edit.original = text.clone();
            edit.sent = sent;
            edit.sent_changed = false;
        });
        kept::save(engine);
        self.set_text_end(engine, target, &text);
        true
    }

    /// Saves the edit. The MC applies saves in the order they come: a
    /// second waits for the first's answer rather than racing it, and the
    /// newest one is what goes.
    pub(super) fn save_queued_edit(&mut self, engine: &Engine, target: &str, text: &str) -> bool {
        let Some(thread) = thread_of(engine, target) else {
            return true;
        };
        let edit = kept::write(engine, |d| {
            let edit = d.queued_edits.get_mut(target)?;
            if edit.saving {
                edit.next = Some(text.to_owned());
                return None;
            }
            Some(edit.clone())
        });
        let Some(edit) = edit else {
            return true;
        };
        let added = kept::read(engine, |d| {
            d.drafts
                .get(target)
                .map(|k| k.attachments.clone())
                .unwrap_or_default()
        });
        // The MC refuses a message left with nothing in it.
        if text.trim().is_empty() && edit.sent.is_empty() && added.is_empty() {
            toast_error(engine, "A queued message cannot be left empty.", "");
            return true;
        }
        if self.files_block(engine, &added, "saving") {
            return true;
        }
        kept::write(engine, |d| {
            if let Some(edit) = d.queued_edits.get_mut(target) {
                edit.saving = true;
            }
        });
        let command = json!({
            "type": "queued-run.edit",
            "threadId": thread.id,
            "runId": edit.run_id,
            "text": text.trim(),
        });
        let added_ids: Vec<String> = added.iter().map(|a| a.id.clone()).collect();
        // Text alone keeps the attachments the message has.
        if !edit.sent_changed && added.is_empty() {
            self.dispatch_queued_edit(
                target,
                &edit.run_id,
                added_ids,
                &thread.environment_id,
                command,
            );
            self.publish(engine);
            return true;
        }
        // New images are stored for the message first, as a send's are; one
        // a refused save already stored is not stored again.
        let new_images: Vec<Attachment> = added
            .iter()
            .filter(|a| !a.file && !edit.stored.contains_key(&a.id))
            .cloned()
            .collect();
        if new_images.is_empty() {
            let command = with_attachments(engine, target, &added, command);
            self.dispatch_queued_edit(
                target,
                &edit.run_id,
                added_ids,
                &thread.environment_id,
                command,
            );
            self.publish(engine);
            return true;
        }
        let image_ids: Vec<String> = new_images.iter().map(|a| a.id.clone()).collect();
        let target = target.to_owned();
        let run_id = edit.run_id.clone();
        let environment_id = thread.environment_id.clone();
        self.mc.call(
            &thread.environment_id,
            "assets.persistChatAttachments",
            json!({"threadId": thread.id, "messageId": edit.message_id,
                   "attachments": image_records(&new_images)}),
            back(&self.me, move |c, engine, result| {
                let current = kept::read(engine, |d| {
                    d.queued_edits
                        .get(&target)
                        .is_some_and(|e| e.run_id == run_id)
                });
                if !current {
                    return;
                }
                match result {
                    Err(error) => {
                        let next = kept::write(engine, |d| {
                            let edit = d.queued_edits.get_mut(&target)?;
                            edit.saving = false;
                            edit.next.take()
                        });
                        toast_error(engine, SAVE_FAILED, &error.message);
                        if let Some(next) = next {
                            c.save_queued_edit(engine, &target, &next);
                            return;
                        }
                        c.publish(engine);
                    }
                    Ok(answer) => {
                        let stored = answer["attachments"]
                            .as_array()
                            .cloned()
                            .unwrap_or_default();
                        kept::write(engine, |d| {
                            if let Some(edit) = d.queued_edits.get_mut(&target) {
                                for (id, record) in image_ids.iter().zip(stored) {
                                    edit.stored.insert(id.clone(), record);
                                }
                            }
                        });
                        let command = with_attachments(engine, &target, &added, command);
                        c.dispatch_queued_edit(
                            &target,
                            &run_id,
                            added_ids,
                            &environment_id,
                            command,
                        );
                    }
                }
            }),
        );
        self.publish(engine);
        true
    }

    fn dispatch_queued_edit(
        &self,
        target: &str,
        run_id: &str,
        added_ids: Vec<String>,
        environment_id: &str,
        command: Json,
    ) {
        let target = target.to_owned();
        let run_id = run_id.to_owned();
        let sent = command.clone();
        self.mc.dispatch_command(
            environment_id,
            command,
            back(&self.me, move |c, engine, result| {
                let next = kept::write(engine, |d| {
                    let edit = d.queued_edits.get_mut(&target)?;
                    if edit.run_id != run_id {
                        return None;
                    }
                    edit.saving = false;
                    Some(edit.next.take())
                });
                let Some(next) = next else {
                    return;
                };
                match result {
                    Err(error) => toast_error(engine, SAVE_FAILED, &error.message),
                    Ok(_) => {
                        // What went with the message is the message's now.
                        kept::write(engine, |d| {
                            if let Some(draft) = d.drafts.get_mut(&target) {
                                draft.attachments.retain(|a| !added_ids.contains(&a.id));
                            }
                        });
                        kept::save(engine);
                        let saved = string(&sent, "text");
                        // Words typed since are a newer edit, left open over
                        // what was saved.
                        if next.is_none() && kept::draft(engine, &target).trim() == saved {
                            c.end_queued_edit(engine, &target, false);
                            return;
                        }
                        // The next save starts from what this one saved.
                        kept::write(engine, |d| {
                            if let Some(edit) = d.queued_edits.get_mut(&target) {
                                edit.original = saved;
                                if let Some(attachments) = sent["attachments"].as_array() {
                                    edit.sent = attachments.clone();
                                    edit.sent_changed = false;
                                }
                            }
                        });
                    }
                }
                if let Some(next) = next {
                    c.save_queued_edit(engine, &target, &next);
                    return;
                }
                c.publish(engine);
            }),
        );
    }

    /// `thread`'s edit ends: its draft comes back, the set-aside attachments
    /// ahead of any added since, unless `keep` leaves the edit as the draft.
    pub(super) fn end_queued_edit(&mut self, engine: &Engine, thread: &str, keep: bool) {
        let edit = kept::write(engine, |d| {
            let edit = d.queued_edits.remove(thread)?;
            let draft = d.drafts.entry(thread.to_owned()).or_default();
            let added = std::mem::take(&mut draft.attachments);
            draft.attachments = edit.saved_attachments.clone();
            draft.attachments.extend(added);
            Some(edit)
        });
        let Some(edit) = edit else {
            return;
        };
        kept::save(engine);
        if keep {
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

    /// Each edit whose message left the queue (it ran, or another device
    /// removed it) ends, kept if it is all its draft holds; a deleted
    /// thread's ends with it.
    pub(super) fn recover_queued_edits(&mut self, engine: &Engine) {
        if kept::read(engine, |d| d.queued_edits.is_empty()) {
            return;
        }
        // Rows read from the cache or held for an MC are not the MC's word:
        // a missing row there says nothing about the thread.
        if !store::with(engine, |s| s.synchronized()) {
            return;
        }
        let threads: Vec<String> = kept::read(engine, |d| d.queued_edits.keys().cloned().collect());
        for thread in threads {
            let Some(edit) = kept::read(engine, |d| d.queued_edits.get(&thread).cloned()) else {
                continue;
            };
            if edit.saving {
                continue;
            }
            let Some(row) = thread_of(engine, &thread) else {
                self.end_queued_edit(engine, &thread, false);
                continue;
            };
            // The thread's queue is known while its stream is live; still
            // queued, its run waits and its message is there to edit.
            let still = threads::timeline_of(engine, &thread).and_then(|obj| {
                TimelineModel::read(engine, obj, |t| {
                    if t.status() != "live" {
                        return true;
                    }
                    t.entities("run").get(&edit.run_id).is_some_and(|run| {
                        field(run, "status") == "queued"
                            && t.entities("message")
                                .contains_key(field(run, "userMessageId"))
                    })
                })
            });
            if still != Some(false) {
                continue;
            }
            let dirty = kept::draft(engine, &thread) != edit.original
                || edit.sent_changed
                || kept::read(engine, |d| {
                    d.drafts
                        .get(&thread)
                        .is_some_and(|k| !k.attachments.is_empty())
                });
            let keep = dirty && edit.saved.trim().is_empty();
            self.end_queued_edit(engine, &thread, keep);
            if !dirty {
                continue;
            }
            let detail = match (thread == self.thread, keep) {
                (true, true) => "Your unsaved edit was kept in the composer.".to_owned(),
                (true, false) => "Your unsaved edit was discarded.".to_owned(),
                (false, true) => format!(
                    "Your unsaved edit in \u{201c}{}\u{201d} was kept in its composer.",
                    row.title
                ),
                (false, false) => format!(
                    "Your unsaved edit in \u{201c}{}\u{201d} was discarded.",
                    row.title
                ),
            };
            toast(
                engine,
                if keep { "info" } else { "warning" },
                "Queued message is no longer queued",
                &detail,
            );
        }
    }

    /// An image the thread's timeline shows, by the address the MC signed;
    /// empty until it comes, asked for once.
    pub(super) fn sent_address(&self, engine: &Engine, id: &str) -> String {
        let Some(obj) = self.timeline else {
            return String::new();
        };
        if id.is_empty() {
            return String::new();
        }
        let known =
            TimelineModel::read(engine, obj, |t| t.attachment_address(id).map(str::to_owned))
                .flatten();
        if let Some(url) = known {
            return url;
        }
        // Not from inside building the state: the answer publishes again.
        let id = id.to_owned();
        later(&self.me, engine, move |_, engine| {
            TimelineModel::update(engine, obj, |t| t.load_attachment(&id));
        });
        String::new()
    }

    /// The attachments the queued message being edited still carries, as
    /// composer chips ahead of the draft's.
    pub(super) fn shown_sent(&self, engine: &Engine, target: &str) -> Vec<Json> {
        let sent = kept::read(engine, |d| {
            d.queued_edits
                .get(target)
                .map(|e| e.sent.clone())
                .unwrap_or_default()
        });
        sent.iter()
            .map(|attachment| {
                let image = string(attachment, "type") == "image";
                let id = string(attachment, "id");
                let mut entry = json!({
                    "id": id,
                    "name": string(attachment, "name"),
                    "mimeType": string(attachment, "mimeType"),
                    "kind": if image { "image" } else { "file" },
                    "status": "",
                    "error": "",
                    "source": null,
                    "sent": true,
                });
                if image {
                    entry["preview"] = json!(self.sent_address(engine, &id));
                }
                entry
            })
            .collect()
    }
}
