//! What the composer publishes: the route thread's requests (`turn`), the
//! composer (`composer`), the picker (`modelPicker`) and the stash
//! (`composerStash`); and the suggestions and @ search behind them.

use std::time::{Duration, Instant};

use serde_json::json;

use super::attachments::shown_attachments;
use super::kept::{self, Attachment};
use super::text::{self, approval_title, default_approval_options, items_of, review_label};
use super::{Composer, FolderAsk, PathSearch, back, later, setting, thread_of};
use crate::composer_model::{self as model, Instance, Suggestion, Trigger};
use crate::controllers::drafts;
use crate::controllers::keybindings::Keymap;
use crate::controllers::settings::Settings;
use crate::controllers::workspace;
use crate::json::Json;
use crate::store;
use crate::thread_view::summary::{Obj, as_object, text as field};
use crate::thread_view::timeline::plan_title;
use ljos::prelude::Engine;

fn or_null(value: &str) -> Json {
    if value.is_empty() {
        Json::Null
    } else {
        json!(value)
    }
}

/// A selection's options, as the descriptors read them.
pub(super) fn options_of(selection: &Obj) -> Vec<Json> {
    selection
        .get("options")
        .and_then(Json::as_array)
        .cloned()
        .unwrap_or_default()
}

impl Composer {
    /// The route thread's requests, plan and queue; a draft's sending.
    pub(super) fn turn_state(&self, engine: &Engine) -> Json {
        if self.on_page() {
            return self.page_turn_state();
        }
        if self.on_images() {
            return self.images_turn_state(engine);
        }
        let thread = thread_of(engine, &self.thread);
        let running = thread.as_ref().is_some_and(|t| t.active_run_id.is_some());
        if !self.draft_id.is_empty() {
            let kept = drafts::draft(engine, &self.draft_id).is_some();
            return json!({
                "threadKey": if kept { self.draft_id.as_str() } else { "" },
                "kind": "draft",
                "running": false,
                "sending": self.launching.contains(&self.draft_id),
                "approvals": [],
                "questions": [],
                "plan": null,
                "queue": [],
                "waiting": [],
                "queueHeld": false,
                "queueResuming": false,
            });
        }
        let mut state = json!({
            "threadKey": if thread.is_some() { self.thread.as_str() } else { "" },
            "kind": "thread",
            "running": running,
            "approvals": [],
            "questions": [],
            "plan": null,
            "tasks": null,
            "queue": [],
            "waiting": [],
            "queueHeld": false,
            "queueResuming": kept::read(engine, |d| d.resuming.contains(&self.thread)),
            // A queue action waits for the MC's answer before another can
            // be taken.
            "queueBusy": self.queue_busy.contains(&self.thread),
            "queueEditBlocked": "",
        });
        let (Some(_), Some(obj)) = (&thread, self.timeline) else {
            return state;
        };
        let answer_files = kept::read(engine, |d| d.answer_files.clone());
        // A follow-up on its way to the MC, with what it carries.
        let on_the_way: Vec<(Obj, Vec<Json>)> = kept::read(engine, |d| {
            d.queues
                .get(&self.thread)
                .into_iter()
                .flatten()
                .flat_map(|send| {
                    let attachments: Vec<Json> = send
                        .attachments
                        .iter()
                        .map(|a| {
                            json!({"id": a.id, "name": a.name, "mimeType": a.mime_type,
                                   "kind": if a.file { "file" } else { "image" }})
                        })
                        .collect();
                    send.commands
                        .iter()
                        .filter(|command| {
                            field(command, "type") == "message.dispatch"
                                && field(
                                    as_object(command.get("dispatchMode").unwrap_or(&Json::Null)),
                                    "type",
                                ) == "queue_after_active"
                        })
                        .map(move |command| (command.clone(), attachments.clone()))
                        .collect::<Vec<_>>()
                })
                .collect()
        });
        let read = crate::thread_view::timeline_model::TimelineModel::read(engine, obj, |t| {
            let items = t.entities("turn-item");
            let requests = t.entities("runtime-request");
            let runs = t.entities("run");
            // A pending request, and whether it can still be answered.
            let pending = |item: &Obj, approval: bool| -> Option<Obj> {
                let request_id = field(item, "requestId");
                let request = requests.get(request_id)?;
                if field(request, "status") != "pending" || self.closed.contains(request_id) {
                    return None;
                }
                let capability = field(
                    as_object(request.get("responseCapability").unwrap_or(&Json::Null)),
                    "type",
                );
                let gone = capability == "not_resumable";
                let mut shown = Obj::new();
                shown.insert("requestId".into(), json!(request_id));
                shown.insert(
                    "canRespond".into(),
                    json!(if approval {
                        capability.is_empty() || capability == "live"
                    } else {
                        !gone
                    }),
                );
                shown.insert(
                    "problem".into(),
                    json!(if gone { text::PROVIDER_GONE } else { "" }),
                );
                shown.insert(
                    "responding".into(),
                    json!(self.responding.contains(request_id)),
                );
                Some(shown)
            };
            let mut approvals = Vec::new();
            for item in items_of(items, "approval_request") {
                let Some(mut approval) = pending(item, true) else {
                    continue;
                };
                let title = approval_title(field(item, "requestKind"));
                let options: Vec<Json> = item
                    .get("options")
                    .and_then(Json::as_array)
                    .into_iter()
                    .flatten()
                    .map(|value| {
                        let option = as_object(value);
                        json!({
                            "decision": field(option, "decision"),
                            "label": field(option, "label"),
                            "warning": field(option, "warning"),
                        })
                    })
                    .collect();
                let prompt = field(item, "prompt");
                approval.insert("title".into(), json!(title));
                approval.insert("appName".into(), json!(field(item, "appName")));
                approval.insert(
                    "detail".into(),
                    json!(if prompt.is_empty() { title } else { prompt }),
                );
                approval.insert(
                    "options".into(),
                    if options.is_empty() {
                        default_approval_options()
                    } else {
                        Json::Array(options)
                    },
                );
                approvals.push(Json::Object(approval));
            }
            let mut questions = Vec::new();
            for item in items_of(items, "user_input_request") {
                let Some(mut question) = pending(item, false) else {
                    continue;
                };
                // Each question with the files attached to its answer.
                let files = answer_files.get(field(&question, "requestId"));
                let asked: Vec<Json> = item
                    .get("questions")
                    .and_then(Json::as_array)
                    .into_iter()
                    .flatten()
                    .map(|value| {
                        let mut one = as_object(value).clone();
                        let attached: &[Attachment] = files
                            .and_then(|f| f.get(field(&one, "id")))
                            .map_or(&[], Vec::as_slice);
                        one.insert(
                            "attachments".into(),
                            Json::Array(shown_attachments(attached, None)),
                        );
                        Json::Object(one)
                    })
                    .collect();
                question.insert("questions".into(), Json::Array(asked));
                questions.push(Json::Object(question));
            }
            // The proposed plan still waiting on the user, from the latest
            // run; offered once the thread is idle.
            let mut plan = Json::Null;
            if !running {
                let mut latest: Option<&Obj> = None;
                let mut latest_ordinal = -1.0;
                for candidate in t.entities("plan").values() {
                    if field(candidate, "kind") != "proposed_plan"
                        || field(candidate, "status") != "active"
                    {
                        continue;
                    }
                    let ordinal = runs
                        .get(field(candidate, "runId"))
                        .and_then(|run| run.get("ordinal"))
                        .map_or(0.0, text::number);
                    if ordinal >= latest_ordinal {
                        latest_ordinal = ordinal;
                        latest = Some(candidate);
                    }
                }
                if let Some(latest) = latest {
                    let markdown = field(latest, "markdown");
                    // `heading` is empty for a plan with none; `fileName`
                    // and `workspaceRoot` start the dialog that saves it to
                    // the workspace.
                    let title = plan_title(markdown);
                    let headed = !crate::controllers::plan::title_of(markdown).is_empty();
                    plan = json!({
                        "id": field(latest, "id"),
                        "heading": if headed { title.as_str() } else { "" },
                        "title": title,
                        "markdown": markdown,
                        "fileName": crate::controllers::plan::file_name(markdown),
                        "workspaceRoot": crate::controllers::plan::workspace_root(engine, &self.thread),
                    });
                }
            }
            // The running turn's task list (ChatView's
            // activeComposerTasksProgress): the step in progress, else the
            // next pending one, else the last; how many are done; and each
            // step with its status and how long it took. Not shown while an
            // approval or a question waits above the composer.
            let mut tasks = Json::Null;
            let active_run = thread.as_ref().and_then(|t| t.active_run_id.as_deref());
            if let Some(run_id) = active_run
                && approvals.is_empty()
                && questions.is_empty()
            {
                let mut list: Option<&Obj> = None;
                for candidate in t.entities("plan").values() {
                    if field(candidate, "kind") == "todo_list"
                        && field(candidate, "runId") == run_id
                        && field(candidate, "status") != "superseded"
                    {
                        list = Some(candidate);
                    }
                }
                let steps: Vec<Json> = list
                    .and_then(|list| list.get("steps"))
                    .and_then(Json::as_array)
                    .cloned()
                    .unwrap_or_default();
                if !steps.is_empty() {
                    let mut shown = Vec::new();
                    let (mut current, mut next, mut completed) = (String::new(), String::new(), 0);
                    for value in &steps {
                        let step = as_object(value);
                        let step_text = field(step, "text");
                        let status = field(step, "status");
                        if status == "completed" {
                            completed += 1;
                        }
                        if status == "running" && current.is_empty() {
                            current = step_text.to_owned();
                        }
                        if status == "pending" && next.is_empty() {
                            next = step_text.to_owned();
                        }
                        let duration = match step.get("durationMs").and_then(Json::as_f64) {
                            Some(ms) => crate::thread_view::time::format_duration(ms as i64),
                            None if status == "running" => "now".to_owned(),
                            None => String::new(),
                        };
                        shown.push(
                            json!({"text": step_text, "status": status, "duration": duration}),
                        );
                    }
                    if current.is_empty() {
                        current = next;
                    }
                    if current.is_empty() {
                        current = steps
                            .last()
                            .map(|last| field(as_object(last), "text").to_owned())
                            .unwrap_or_default();
                    }
                    tasks = json!({"current": current, "completed": completed,
                                   "total": steps.len(), "steps": shown});
                }
            }
            let messages = t.entities("message");
            let queued = model::queued(runs.values(), |id| messages.get(id));
            // Listed at the end as being saved, with nothing to do to it
            // until the MC has it.
            let pending: Vec<Json> = on_the_way
                .iter()
                .filter(|(command, _)| !messages.contains_key(field(command, "messageId")))
                .map(|(command, attachments)| {
                    let words = field(command, "text");
                    json!({"runId": "", "messageId": field(command, "messageId"),
                           "text": words, "shown": text::quoted_plainly(words),
                           "attachments": attachments, "pending": true})
                })
                .collect();
            (approvals, questions, plan, tasks, queued, pending)
        });
        if let Some((approvals, questions, plan, tasks, mut queued, pending)) = read {
            // Why the queued messages cannot be edited now, empty when they
            // can.
            state["queueEditBlocked"] = json!(if questions.is_empty() {
                ""
            } else {
                "Answer the question to edit queued messages"
            });
            for entry in &mut queued.queue {
                let words = entry["text"].as_str().unwrap_or_default().to_owned();
                entry["shown"] = json!(text::quoted_plainly(&words));
                entry["pending"] = json!(false);
                if let Some(attachments) = entry["attachments"].as_array_mut() {
                    for attachment in attachments {
                        if attachment["kind"] == "image" {
                            let id = attachment["id"].as_str().unwrap_or_default().to_owned();
                            attachment["url"] = json!(self.sent_address(engine, &id));
                        }
                    }
                }
            }
            queued.queue.extend(pending);
            state["approvals"] = Json::Array(approvals);
            state["questions"] = Json::Array(questions);
            state["plan"] = plan;
            state["tasks"] = tasks;
            // Held with nothing listed shows no card, so it offers no resume
            // either. A queued run comes with its message in the one
            // transaction that queues it (the MC's `queue_run`), so a run
            // without its message on a live stream is the moment before the
            // two events are read, not a state that lasts; an empty card in
            // that moment would only flash.
            state["queueHeld"] = json!(queued.shown_held());
            state["queue"] = Json::Array(queued.queue);
            state["waiting"] = Json::Array(queued.waiting);
        }
        state
    }

    /// Whether the MC holds this thread's queue, with something listed to
    /// resume: the one fact `resume_queue` needs, without building the whole
    /// turn state.
    pub(super) fn queue_held(&self, engine: &Engine) -> bool {
        if !self.draft_id.is_empty() || thread_of(engine, &self.thread).is_none() {
            return false;
        }
        self.read_timeline(engine, |t| {
            let messages = t.entities("message");
            model::queued(t.entities("run").values(), |id| messages.get(id)).shown_held()
        })
    }

    /// ShellComposerState; null with no thread or draft open.
    pub(super) fn composer_state(&mut self, engine: &Engine, turn: &Json) -> Json {
        let target = self.target(engine);
        if target.is_empty() {
            return Json::Null;
        }
        if self.on_images() {
            return self.images_composer_state(engine);
        }
        let is_draft = !self.draft_id.is_empty();
        let thread = thread_of(engine, &target);
        let kept = kept::draft_of(engine, &target);
        let text = kept::draft(engine, &target);
        let cursor = kept.cursor.clamp(0, model::utf16_len(&text) as i64);
        let chosen = self.selection(engine, &target);
        // Thumbnails first: they update the previews the instance borrow
        // would hold.
        // The queued message being edited lists what it carries first.
        let mut attachments = self.shown_sent(engine, &target);
        attachments.extend(self.shown_with_previews(engine, &kept.attachments));
        let instance = self.instance_of(&chosen);
        let plan_on = self.plan_mode_on(engine, instance);

        let trigger = if kept.dismissed {
            None
        } else {
            self.trigger_of(engine, &target, &text, cursor)
        };
        let suggestions: Vec<Json> = self
            .suggestions(engine, &target, trigger.as_ref())
            .into_iter()
            .map(|item| {
                json!({
                    "id": item.id,
                    "kind": item.kind,
                    "label": item.label,
                    "description": item.description,
                })
            })
            .collect();
        let mut empty_text = Json::Null;
        if let Some(trigger) = &trigger
            && suggestions.is_empty()
        {
            // A path search says it is searching until it has answered,
            // and that it could not search when it cannot or failed. A bare
            // `@` is not searched, so it says nothing matches at once, as
            // the web's menu did.
            let searched = trigger.kind == "path" && !trigger.query.is_empty();
            let answered =
                self.paths.target == target && self.paths.query == trigger.query && self.paths.done;
            let empty = model::empty_text(&trigger.kind);
            let unavailable = if answered {
                self.paths.failed
            } else {
                !self.can_search_paths(engine, &target)
            };
            if searched && unavailable {
                empty_text = json!(model::PATH_SEARCH_UNAVAILABLE);
            } else if searched && !answered {
                empty_text = json!(model::PATH_SEARCHING);
            } else if !empty.is_empty() {
                empty_text = json!(empty);
            }
        }

        let mut terminal_contexts = Vec::new();
        let mut review_comments = Vec::new();
        let mut citations = Vec::new();
        for excerpt in &kept.excerpts {
            if !excerpt.citation.is_empty() {
                let comment = match excerpt.citation.get("comment") {
                    Some(Json::String(comment)) => json!(comment),
                    _ => Json::Null,
                };
                citations.push(json!({
                    "id": excerpt.id,
                    "text": field(&excerpt.citation, "text"),
                    "comment": comment,
                }));
                continue;
            }
            if !excerpt.review.is_empty() {
                let file_path = field(&excerpt.review, "filePath");
                review_comments.push(json!({
                    "id": excerpt.id,
                    "label": review_label(file_path, excerpt.line_start, excerpt.line_end),
                    "filePath": file_path,
                    "lineStart": excerpt.line_start,
                    "lineEnd": excerpt.line_end,
                    "text": excerpt.text,
                }));
                continue;
            }
            terminal_contexts.push(json!({
                "id": excerpt.id,
                "label": excerpt.terminal_label,
                "lineStart": excerpt.line_start,
                "lineEnd": excerpt.line_end,
            }));
        }
        let approvals = turn["approvals"].as_array().map_or(0, Vec::len);
        let questions = turn["questions"].as_array().map_or(0, Vec::len);
        let first_question = as_object(&turn["questions"][0]["questions"][0]);
        let choice_only = !first_question.is_empty()
            && !first_question
                .get("allowCustomAnswer")
                .and_then(Json::as_bool)
                .unwrap_or(false);
        let plan_offered = !turn["plan"].is_null();
        let show_plan_follow_up = plan_offered && !kept.carries();
        let plan_action = if !show_plan_follow_up {
            ""
        } else if text.trim().is_empty() {
            "implement"
        } else {
            "refine"
        };
        let mut environment_id = thread
            .as_ref()
            .map(|t| t.environment_id.clone())
            .unwrap_or_default();
        if is_draft && let Some(draft) = drafts::draft(engine, &target) {
            environment_id = draft.environment_id;
        }
        let offline = !store::with(engine, |s| s.environment_online(&environment_id));
        let no_provider = !self.catalogue.iter().any(Instance::ready);
        let busy = is_draft && self.launching.contains(&target);
        let has_content = !text.trim().is_empty() || kept.carries();
        let is_running = thread.as_ref().is_some_and(|t| t.active_run_id.is_some());

        let placeholder = if approvals > 0 {
            "Resolve this approval request to continue"
        } else if show_plan_follow_up {
            "Add feedback to refine the plan, or leave this blank to implement it"
        } else if no_provider {
            "Enable a provider in Settings to send a message"
        } else if offline {
            "Ask for changes, send follow-ups, or attach images"
        } else {
            "Ask anything, @tag files/folders, $use skills, or / for commands"
        };
        // A started thread whose own provider cannot run here sends nothing
        // until the user picks one: the composer never swaps it for another.
        // One the catalogue cannot judge yet (none listed, or none named) is
        // the MC's to run.
        let needs_pick = !is_draft
            && kept.model_selection.is_none()
            && thread
                .as_ref()
                .is_some_and(|t| !t.model_selection.is_empty())
            && !self.catalogue.is_empty()
            && !instance.is_some_and(Instance::ready);
        let disabled_reason = if offline {
            json!("Not connected")
        } else if no_provider {
            json!("No provider available")
        } else if needs_pick {
            json!("Choose a model to send")
        } else {
            Json::Null
        };

        let keymap = Keymap::of(engine);
        let selected_instance = field(&chosen, "instanceId");
        let selected_model = field(&chosen, "model");
        let described = instance
            .map(|i| {
                model::descriptors(
                    &model::find_model(i, selected_model),
                    &options_of(&chosen),
                    plan_on,
                )
            })
            .unwrap_or_default();
        let mut options = model::shell_options(&described);
        // An effort the prompt asks for (Ultrathink) is only typed: the
        // choices leave it out unless the prompt asks for it, when it is the
        // one shown. Asked for in the prompt's own words, it cannot be
        // changed until they go.
        let in_words = model::ultrathink_in_words(&text);
        let asked = text.trim().starts_with(text::ULTRATHINK_PREFIX.trim()) || in_words;
        for (option, descriptor) in options.iter_mut().zip(&described) {
            let injected = descriptor["promptInjectedValues"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            let Some(first) = injected.first().cloned() else {
                continue;
            };
            if asked {
                option["value"] = first.clone();
            }
            if let Some(choices) = option["choices"].as_array_mut() {
                choices.retain(|choice| {
                    !injected.contains(&choice["id"]) || (asked && choice["id"] == first)
                });
            }
            if in_words {
                option["lockedReason"] = json!(
                    "Your prompt contains \"ultrathink\" in the text. Remove it to change this option."
                );
            }
        }
        // The effort is marked, with its bars for the composer to draw when
        // Appearance asks for them.
        if let Some(at) = model::effort_index(&described)
            && let Some(option) = options.get_mut(at)
        {
            option["effort"] = json!(true);
            let current = option["value"].as_str().unwrap_or_default().to_owned();
            if let Some(bars) = model::effort_bars(as_object(&described[at]), &current) {
                option["bars"] = bars;
            }
        }
        let follow_up = if setting(engine, "followUpBehavior").as_str() == Some("queue") {
            "queue"
        } else {
            "steer"
        };
        let send_shortcut = setting(engine, "sendShortcut");
        let editing = kept::read(engine, |d| {
            d.queued_edits.get(&target).map(|edit| edit.run_id.clone())
        });
        let sending = kept::read(engine, |d| d.queues.contains_key(&target));
        let mut state = json!({
            "target": target,
            "routeKind": if is_draft { "draft" } else { "server" },
            // The branch and worktree controls under the composer: a new
            // thread's, and kept once it has started only when the user asks.
            "showContextStrip": is_draft
                || setting(engine, "persistComposerContextStrip").as_bool().unwrap_or(false),
            "edit": kept.edit,
            "text": text,
            "cursor": cursor,
            "triggerKind": trigger.as_ref().map_or(Json::Null, |t| json!(t.kind)),
            "suggestions": suggestions,
            "suggestionsEmptyText": empty_text,
            "attachments": attachments,
            "terminalContexts": terminal_contexts,
            "reviewComments": review_comments,
            "citations": citations,
            "placeholder": placeholder,
            "editorDisabled": approvals > 0 || choice_only,
            "canSend": !(busy || offline || no_provider || needs_pick) && (has_content || show_plan_follow_up),
            "sendDisabledReason": disabled_reason,
            "isRunning": is_running,
            "followUpBehavior": follow_up,
            "effortDisplay": if setting(engine, "effortDisplay").as_str() == Some("bars") { "bars" } else { "label" },
            "enterIntents": model::enter_intents(
                &keymap.bindings(),
                keymap.mac(),
                send_shortcut.as_str().unwrap_or_default(),
                is_draft,
                is_running,
            ),
            // A first message launching, or a message on its way to the MC.
            "isSendBusy": busy || sending,
            "isConnecting": false,
            "pendingApprovalCount": approvals,
            "pendingUserInputCount": questions,
            "showPlanFollowUpPrompt": show_plan_follow_up,
            // What sending does to the offered plan (ComposerPrimaryActions):
            // "implement" with nothing typed, "refine" with feedback, else empty.
            "planAction": plan_action,
            "selectedInstanceId": or_null(selected_instance),
            "selectedModel": or_null(selected_model),
            "options": options,
            "runtimeMode": model::shown_runtime_mode(instance, &self.runtime_mode_of(engine, &target)),
            "defaultRuntimeMode": model::shown_runtime_mode(instance, &self.default_runtime_mode_of(engine, &target)),
            "runtimeModes": model::runtime_modes(instance),
            "interactionMode": self.interaction_mode_of(engine, &target),
            "showInteractionModeToggle": plan_on,
            "usageLimits": self.usage_limits.get(&target).cloned().unwrap_or(Json::Null),
            "editingQueuedRunId": editing.map_or(Json::Null, Json::String),
        });
        if self.on_page() {
            self.page_composer_state(engine, &target, &mut state);
        }
        state
    }

    /// ShellModelPickerState: the rail for the route's thread or draft.
    pub(super) fn picker_state(&self, engine: &Engine) -> Json {
        let target = self.target(engine);
        let thread = thread_of(engine, &target);
        let chosen = self.selection(engine, &target);
        let current = thread
            .as_ref()
            .map(|t| t.model_selection.clone())
            .unwrap_or_default();
        let settings = Settings::of(engine);
        let prefs = model::model_prefs(
            &settings.device_value("favorites").unwrap_or(Json::Null),
            &settings
                .device_value("providerModelPreferences")
                .unwrap_or(Json::Null),
        );
        let keymap = Keymap::of(engine);
        let bindings = keymap.bindings();
        let key = |command: &str| model::picker_key(&bindings, keymap.mac(), command);
        let jump: Vec<Json> = (1..=9)
            .map(|n| key(&format!("modelPicker.jump.{n}")))
            .collect();
        let toggle = key("modelPicker.toggle");
        let multiple = kept::read(engine, |d| {
            d.drafts
                .get(&target)
                .and_then(|k| k.multiple_models.clone())
        });
        let instances = match self.images_picker_instances(engine) {
            Some(images) => Json::Array(images),
            None => json!(model::picker_instances(
                &self.catalogue,
                &prefs,
                field(&chosen, "instanceId"),
                field(&chosen, "model"),
                thread.as_ref().is_some_and(|t| t.runtime.is_some()),
                field(&current, "instanceId"),
                field(&current, "model"),
            )),
        };
        let images = self.on_images();
        let stand_in = model::no_provider_stand_in(&self.catalogue);
        json!({
            "instances": instances,
            "locked": !images && thread.as_ref().is_some_and(|t| t.runtime.is_some()),
            // What stands where the model would be when no provider can run
            // a turn.
            "noProvider": if images || stand_in.is_empty() { Json::Null } else { json!(stand_in) },
            // Image models are not starred.
            "favorites": !images,
            // A new thread may go to several models: [{instanceId, model}]
            // once more than one is chosen.
            "supportsMultiple": !self.draft_id.is_empty() && target == self.draft_id,
            "multiple": multiple.map_or(Json::Null, |models| {
                Json::Array(models.into_iter().map(Json::Object).collect())
            }),
            "shortcut": if toggle.is_null() { Json::Null } else { toggle["label"].clone() },
            "previousProvider": key("modelPicker.previousProvider"),
            "nextProvider": key("modelPicker.nextProvider"),
            "jump": jump,
        })
    }

    /// What the stash menu shows: each entry with a snippet of its text.
    pub(super) fn stash_state(&self, engine: &Engine) -> Json {
        let entries: Vec<Json> = kept::read(engine, |d| {
            d.stash
                .iter()
                .map(|entry| {
                    json!({
                        "id": entry.id,
                        "snippet": text::stash_snippet(entry),
                        "createdAt": entry.created_at,
                    })
                })
                .collect()
        });
        json!({
            "entries": entries,
            "open": self.stash_open,
            "shortcut": Keymap::of(engine).shortcut_label(engine, "composer.stash"),
        })
    }

    /// The trigger at the draft's caret: a price is no skill, and a slash
    /// word in a sentence that starts no name is prose, so Enter sends it.
    pub(super) fn trigger_of(
        &self,
        engine: &Engine,
        target: &str,
        text: &str,
        cursor: i64,
    ) -> Option<Trigger> {
        let trigger = model::trigger(text, cursor)?;
        if trigger.kind == "skill" {
            let folder = self.commands_of(engine, target);
            if !model::opens_skill_menu(folder.as_ref(), &trigger.query) {
                return None;
            }
        }
        if trigger.mid_line && self.suggestions(engine, target, Some(&trigger)).is_empty() {
            return None;
        }
        self.page_trigger(target, text, trigger)
    }

    pub(super) fn suggestions(
        &self,
        engine: &Engine,
        target: &str,
        trigger: Option<&Trigger>,
    ) -> Vec<Suggestion> {
        let Some(trigger) = trigger else {
            return Vec::new();
        };
        let folder = self.commands_of(engine, target);
        let instance = folder.as_ref();
        match trigger.kind.as_str() {
            "slash-command" => model::slash_items(
                instance,
                trigger,
                self.plan_mode_on(engine, instance),
                setting(engine, "showSkillsInSlashMenu")
                    .as_bool()
                    .unwrap_or(false),
                kept::draft(engine, target).trim() == format!("/{}", trigger.query),
            ),
            "skill" => model::skill_items(instance, trigger),
            "path" if self.paths.target == target && self.paths.query == trigger.query => {
                model::path_items(&self.paths.entries)
            }
            _ => Vec::new(),
        }
    }

    /// The draft's instance with the skills and commands of the folder it
    /// works in, once the MC has read them (`ask_folder`).
    pub(super) fn commands_of(&self, engine: &Engine, target: &str) -> Option<Instance> {
        let selection = self.selection(engine, target);
        let instance = self.instance_of(&selection)?;
        Some(model::in_folder(
            instance,
            &self.search_place(engine, target).1,
        ))
    }

    /// Most providers' skills and many commands are a folder's own (Claude's
    /// and Codex's entries carry none): the MC reads them when a composer
    /// asks for its folder and announces them with the providers, as
    /// `workspaceSnapshots`. Asked once the composer has an instance and a
    /// folder, one read at a time; again after five minutes so a skill added
    /// to the project since shows up; half a minute after a read that
    /// failed; and at once when a catalogue announced since the MC kept the
    /// folder no longer has it (the MC restarted).
    pub(super) fn ask_folder(&mut self, engine: &Engine, target: &str) {
        if target.is_empty() || !self.mc.is_ready() {
            return;
        }
        let selection = self.selection(engine, target);
        let Some(instance) = self.instance_of(&selection).filter(|i| i.enabled) else {
            return;
        };
        let (environment, cwd) = self.search_place(engine, target);
        if cwd.is_empty() || !store::with(engine, |s| s.environment_online(&environment)) {
            return;
        }
        let instance_id = instance.instance_id.clone();
        let key = format!("{environment}\n{instance_id}\n{cwd}");
        if let Some(asked) = self.folders_asked.get(&key) {
            if asked.reading {
                return;
            }
            let lost = asked.kept
                && self.catalogues > asked.answered_at
                && !model::has_read(instance, &cwd);
            if Instant::now() < asked.stands && !lost {
                return;
            }
        }
        self.folders_asked.insert(
            key.clone(),
            FolderAsk {
                reading: true,
                kept: false,
                answered_at: 0,
                stands: Instant::now(),
            },
        );
        self.mc.call(
            &environment,
            "server.refreshProviders",
            json!({"instanceId": instance_id, "cwd": cwd}),
            back(&self.me, move |c, _engine, result| {
                let kept = result.as_ref().is_ok_and(|answer| {
                    let answered = model::instances(
                        answer["providers"]
                            .as_array()
                            .map(Vec::as_slice)
                            .unwrap_or_default(),
                    );
                    model::find(&answered, &instance_id).is_some_and(|i| model::has_read(i, &cwd))
                });
                let wait = if result.is_err() { 30 } else { 300 };
                c.folders_asked.insert(
                    key,
                    FolderAsk {
                        reading: false,
                        kept,
                        answered_at: c.catalogues,
                        stands: Instant::now() + Duration::from_secs(wait),
                    },
                );
            }),
        );
    }

    /// Where `target`'s @ words are searched: the route's own checkout, or
    /// the root of the project a page's ask runs in; empty when it is
    /// neither.
    fn search_place(&self, engine: &Engine, target: &str) -> (String, String) {
        if let Some(place) = self.page_search_place(engine, target) {
            return place;
        }
        match workspace::place(engine) {
            Some(place) if self.target(engine) == target => {
                (place.environment_id.clone(), place.cwd().to_owned())
            }
            _ => (String::new(), String::new()),
        }
    }

    /// Whether that place is known and its environment reachable.
    fn can_search_paths(&self, engine: &Engine, target: &str) -> bool {
        let (environment, cwd) = self.search_place(engine, target);
        !cwd.is_empty() && store::with(engine, |s| s.environment_online(&environment))
    }

    /// A search the environment took down with it (unanswered, or failed)
    /// is forgotten, as is one of a checkout the route has left, so the same
    /// word is asked again once it can be.
    pub(super) fn refresh_path_search(&mut self, engine: &Engine) {
        let target = self.target(engine);
        if target.is_empty() {
            return;
        }
        let paths_target = self.paths.target.clone();
        let mut stale = (!self.paths.done || self.paths.failed)
            && !self.can_search_paths(engine, &paths_target);
        if self.paths.target == target && self.can_search_paths(engine, &target) {
            let (environment, cwd) = self.search_place(engine, &target);
            stale = stale || self.paths.environment_id != environment || self.paths.cwd != cwd;
        }
        if stale && !self.paths.query.is_empty() {
            self.paths = PathSearch {
                request: self.paths.request + 1,
                ..PathSearch::default()
            };
        }
        self.search_paths(engine, &target);
    }

    /// The @ menu asks the MC's workspace search (the Files tab's) for the
    /// route's checkout; the answer counts only while it is still the
    /// question.
    pub(super) fn search_paths(&mut self, engine: &Engine, target: &str) {
        let text = kept::draft(engine, target);
        let cursor = kept::read(engine, |d| d.drafts.get(target).map_or(0, |k| k.cursor));
        let Some(trigger) = self.trigger_of(engine, target, &text, cursor) else {
            return;
        };
        if trigger.kind != "path" || trigger.query.is_empty() {
            return;
        }
        if self.paths.target == target && self.paths.query == trigger.query {
            return;
        }
        if !self.can_search_paths(engine, target) {
            return;
        }
        let (environment, cwd) = self.search_place(engine, target);
        self.paths = PathSearch {
            target: target.to_owned(),
            query: trigger.query.clone(),
            environment_id: environment.clone(),
            cwd: cwd.clone(),
            done: false,
            failed: false,
            entries: Vec::new(),
            request: self.paths.request + 1,
        };
        let request = self.paths.request;
        self.mc.call(
            &environment,
            "projects.searchEntries",
            json!({"cwd": cwd, "query": trigger.query, "limit": 80}),
            back(&self.me, move |c, engine, result| {
                if request != c.paths.request {
                    return;
                }
                c.paths.done = true;
                c.paths.failed = result.is_err();
                if let Ok(found) = result {
                    for entry in found["entries"].as_array().into_iter().flatten() {
                        let path = entry["path"].as_str().unwrap_or_default();
                        if path.is_empty() {
                            continue;
                        }
                        c.paths
                            .entries
                            .push((path.to_owned(), entry["kind"] == "directory"));
                    }
                }
                c.publish(engine);
            }),
        );
    }

    /// The composer's chips for `attachments`, each image with its
    /// thumbnail, made once per image on the compute pool: decoding a
    /// screenshot takes longer than a frame. A chip shows no thumbnail until
    /// its own arrives, which publishes again.
    fn shown_with_previews(&mut self, engine: &Engine, attachments: &[Attachment]) -> Vec<Json> {
        let missing: Vec<&Attachment> = attachments
            .iter()
            .filter(|a| !a.file && !self.previews.contains_key(&a.id))
            .collect();
        if !missing.is_empty() {
            // A new image is when the ones that left the drafts and the
            // stash are forgotten.
            let held: std::collections::HashSet<String> = kept::read(engine, |d| {
                d.drafts
                    .values()
                    .flat_map(|k| &k.attachments)
                    .chain(d.stash.iter().flat_map(|e| &e.attachments))
                    .map(|a| a.id.clone())
                    .collect()
            });
            self.previews.retain(|id, _| held.contains(id));
            self.making.retain(|id, _| held.contains(id));
            for image in missing {
                self.previews.insert(image.id.clone(), String::new());
                self.make_thumbnail(engine, &image.id, &image.data_url);
            }
        }
        shown_attachments(attachments, Some(&self.previews))
    }

    /// Makes image `id`'s thumbnail off the Engine thread; its answer counts
    /// only while `id` still waits on this generation.
    fn make_thumbnail(&mut self, engine: &Engine, id: &str, data_url: &str) {
        self.generation += 1;
        let generation = self.generation;
        self.making.insert(id.to_owned(), generation);
        let me = self.me.clone();
        let made_for = id.to_owned();
        let image = data_url.to_owned();
        let spawned = ljos::task::spawn(
            engine,
            move || super::attachments::thumbnail(&image),
            move |engine, made| {
                later(&me, engine, move |c, engine| {
                    if c.making.get(&made_for) != Some(&generation) {
                        return;
                    }
                    c.making.remove(&made_for);
                    // A thumbnail that panicked is none, as one that does
                    // not decode.
                    c.previews.insert(made_for, made.unwrap_or_default());
                    c.publish(engine);
                });
            },
        );
        if spawned.is_err() {
            // The pool is full: made here, once.
            self.making.remove(id);
            self.previews
                .insert(id.to_owned(), super::attachments::thumbnail(data_url));
        }
    }
}
