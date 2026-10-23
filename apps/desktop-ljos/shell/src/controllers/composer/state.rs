//! What the composer publishes: the route thread's requests (`turn`), the
//! composer (`composer`), the picker (`modelPicker`) and the stash
//! (`composerStash`); and the suggestions and @ search behind them.

use serde_json::json;

use super::attachments::shown_attachments;
use super::kept::{self, Attachment};
use super::text::{self, approval_title, default_approval_options, items_of, review_label};
use super::{Composer, PathSearch, back, later, setting, thread_of};
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
            });
        }
        let mut state = json!({
            "threadKey": if thread.is_some() { self.thread.as_str() } else { "" },
            "kind": "thread",
            "running": running,
            "approvals": [],
            "questions": [],
            "plan": null,
            "queue": [],
            "waiting": [],
        });
        let (Some(_), Some(obj)) = (&thread, self.timeline) else {
            return state;
        };
        let answer_files = kept::read(engine, |d| d.answer_files.clone());
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
                    plan = json!({
                        "id": field(latest, "id"),
                        "title": plan_title(markdown),
                        "markdown": markdown,
                    });
                }
            }
            let messages = t.entities("message");
            let queued = model::queued(runs.values(), |id| messages.get(id));
            (approvals, questions, plan, queued.queue, queued.waiting)
        });
        if let Some((approvals, questions, plan, queue, waiting)) = read {
            state["approvals"] = Json::Array(approvals);
            state["questions"] = Json::Array(questions);
            state["plan"] = plan;
            state["queue"] = Json::Array(queue);
            state["waiting"] = Json::Array(waiting);
        }
        state
    }

    /// ShellComposerState; null with no thread or draft open.
    pub(super) fn composer_state(&mut self, engine: &Engine, turn: &Json) -> Json {
        let target = self.target(engine);
        if target.is_empty() {
            return Json::Null;
        }
        let is_draft = !self.draft_id.is_empty();
        let thread = thread_of(engine, &target);
        let kept = kept::draft_of(engine, &target);
        let text = kept::draft(engine, &target);
        let cursor = kept.cursor.clamp(0, model::utf16_len(&text) as i64);
        let chosen = self.selection(engine, &target);
        // Thumbnails first: they update the previews the instance borrow
        // would hold.
        let attachments = self.shown_with_previews(engine, &kept.attachments);
        let instance = self.instance_of(&chosen);
        let plan_on = self.plan_mode_on(engine, instance);

        let trigger = if kept.dismissed {
            None
        } else {
            model::trigger(&text, cursor)
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
            // A path search says nothing until it has answered. A bare `@`
            // is not searched, so it says so at once, as the web's menu did.
            let waiting = trigger.kind == "path"
                && !trigger.query.is_empty()
                && (self.paths.target != target
                    || self.paths.query != trigger.query
                    || !self.paths.done);
            let empty = model::empty_text(&trigger.kind);
            if !waiting && !empty.is_empty() {
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
        let disabled_reason = if offline {
            json!("Not connected")
        } else if no_provider {
            json!("No provider available")
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
        // An effort the prompt asks for (Ultrathink) is the one shown.
        if instance.is_some() && text.trim().starts_with(text::ULTRATHINK_PREFIX.trim()) {
            for (option, descriptor) in options.iter_mut().zip(&described) {
                if let Some(first) = descriptor["promptInjectedValues"]
                    .as_array()
                    .and_then(|v| v.first())
                {
                    option["value"] = first.clone();
                }
            }
        }
        let follow_up = if setting(engine, "followUpBehavior").as_str() == Some("queue") {
            "queue"
        } else {
            "steer"
        };
        let send_shortcut = setting(engine, "sendShortcut");
        let editing = kept::read(engine, |d| {
            d.queued_edit
                .as_ref()
                .filter(|edit| edit.thread == target)
                .map(|edit| edit.run_id.clone())
        });
        let sending = kept::read(engine, |d| d.queues.contains_key(&target));
        json!({
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
            "canSend": !(busy || offline || no_provider) && (has_content || show_plan_follow_up),
            "sendDisabledReason": disabled_reason,
            "isRunning": is_running,
            "followUpBehavior": follow_up,
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
            "selectedInstanceId": or_null(selected_instance),
            "selectedModel": or_null(selected_model),
            "options": options,
            "runtimeMode": self.runtime_mode_of(engine, &target),
            "runtimeModes": model::runtime_modes(instance),
            "interactionMode": self.interaction_mode_of(engine, &target),
            "showInteractionModeToggle": plan_on,
            "usageLimits": self.usage_limits.get(&target).cloned().unwrap_or(Json::Null),
            "editingQueuedRunId": editing.map_or(Json::Null, Json::String),
        })
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
        json!({
            "instances": model::picker_instances(
                &self.catalogue,
                &prefs,
                field(&chosen, "instanceId"),
                field(&chosen, "model"),
                thread.as_ref().is_some_and(|t| t.runtime.is_some()),
                field(&current, "instanceId"),
                field(&current, "model"),
            ),
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

    pub(super) fn suggestions(
        &self,
        engine: &Engine,
        target: &str,
        trigger: Option<&Trigger>,
    ) -> Vec<Suggestion> {
        let Some(trigger) = trigger else {
            return Vec::new();
        };
        let selection = self.selection(engine, target);
        let instance = self.instance_of(&selection);
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

    /// The @ menu asks the MC's workspace search (the Files tab's) for the
    /// route's checkout; the answer counts only while it is still the
    /// question.
    pub(super) fn search_paths(&mut self, engine: &Engine, target: &str) {
        let text = kept::draft(engine, target);
        let cursor = kept::read(engine, |d| d.drafts.get(target).map_or(0, |k| k.cursor));
        let Some(trigger) = model::trigger(&text, cursor) else {
            return;
        };
        if trigger.kind != "path" || trigger.query.is_empty() {
            return;
        }
        if self.paths.target == target && self.paths.query == trigger.query {
            return;
        }
        let Some(place) = workspace::place(engine) else {
            return;
        };
        if place.cwd().is_empty()
            || !store::with(engine, |s| s.environment_online(&place.environment_id))
        {
            return;
        }
        self.paths = PathSearch {
            target: target.to_owned(),
            query: trigger.query.clone(),
            done: false,
            entries: Vec::new(),
            request: self.paths.request + 1,
        };
        let request = self.paths.request;
        self.mc.call(
            &place.environment_id,
            "projects.searchEntries",
            json!({"cwd": place.cwd(), "query": trigger.query, "limit": 80}),
            back(&self.me, move |c, engine, result| {
                if request != c.paths.request {
                    return;
                }
                c.paths.done = true;
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
