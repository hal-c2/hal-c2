//! The composer on a Space page (desktop-qt's ComposerController with
//! `onPage()`): with no thread or draft open, the page on show takes the
//! prompt, keyed [`page_key`], which no thread key or draft id can be. Plain
//! words write a block (`space.prompt.write` to SpacePage), `/` picks a kind
//! of block from the page's own menu, and words to `@agent` ask an agent
//! about the page (`page.askAgent`), with the model, effort, modes,
//! attachments and excerpts a turn would carry, in the project the MC says
//! (`space.page.agentTarget`) or the one the user picked. Stop stops the
//! page's agent.
//!
//! The images' prompt is in [`super::images`].

use std::rc::Rc;
use std::sync::LazyLock;

use ljos::prelude::Engine;
use regex::Regex;
use serde_json::json;

use super::attachments::{file_records, image_records};
use super::{Composer, kept, later, setting, string, text, toast_error};
use crate::bridge::Bridge;
use crate::composer_model::{self as model, Trigger};
use crate::controller::{self, Controller};
use crate::controllers::keybindings::Keymap;
use crate::controllers::settings::Settings;
use crate::controllers::space::{self, Space};
use crate::controllers::toasts::{DEFAULT_TIMEOUT_MS, Toasts};
use crate::json::Json;
use crate::store;
use crate::thread_view::summary::{Obj, as_object, text as field};

/// Told whether the MC took the prompt.
type Answer = Rc<dyn Fn(&Engine, bool)>;
/// Told which project the page belongs to.
type ProjectAnswer = Rc<dyn Fn(&Engine, String)>;

/// The prompt of the page `page_id`.
pub(super) fn page_key(page_id: &str) -> String {
    format!("page#{page_id}")
}

static ASK: LazyLock<Option<Regex>> = LazyLock::new(|| Regex::new(r"(?i)^@agent(\s|$)").ok());

/// The words of an ask: they start with `@agent`.
fn is_ask(text: &str) -> bool {
    ASK.as_ref().is_some_and(|r| r.is_match(text.trim()))
}

/// A warning toast, as the Space's own prompt showed one.
fn warn(engine: &Engine, title: &str, description: &str) {
    controller::with::<Toasts, _>(engine, |t, e| {
        t.show(e, "warning", title, description, None, DEFAULT_TIMEOUT_MS);
    });
}

const RECONNECTING: &str = "Reconnecting to the environment. Try again once it is connected.";

impl Composer {
    pub(super) fn on_page(&self) -> bool {
        !self.page_id.is_empty()
    }

    /// The page's or the images' prompt while one is open.
    pub(super) fn place_target(&self) -> Option<String> {
        if self.on_page() {
            Some(page_key(&self.page_id))
        } else if self.on_images() {
            Some(super::images::images_key(&self.images_space))
        } else {
            None
        }
    }

    /// Follows the page (else the images) on show, while no thread or
    /// draft is `routed`.
    pub(super) fn follow_place(&mut self, engine: &Engine, routed: bool) {
        let page = if routed {
            String::new()
        } else {
            space::prompt_page(engine)
        };
        if page != self.page_id {
            self.page_id = page;
            if self.on_page() {
                self.ask_page_project(engine);
            }
        } else if self.on_page() && !self.page_project_asked {
            self.ask_page_project(engine);
        }
        // The images' prompt asks what can make an image each time they open.
        let images = if routed || self.on_page() {
            String::new()
        } else {
            space::prompt_images(engine)
        };
        if images != self.images_space {
            self.images_space = images;
            if self.on_images() {
                Bridge::of(engine).defer(engine, |engine| {
                    controller::with::<Space, _>(engine, |s, e| {
                        s.handle(e, "space.image.providers", &json!({}));
                    });
                });
            }
        }
        self.page_running = self.page_agent_running(engine);
    }

    /// The Space changed: a new page or images on show are followed, else
    /// whether the page's agent runs is shown.
    pub(super) fn follow_page(&mut self, engine: &Engine) {
        let routed = !self.thread.is_empty() || !self.draft_id.is_empty();
        let images = if self.on_page() {
            String::new()
        } else {
            space::prompt_images(engine)
        };
        if !routed
            && (space::prompt_page(engine) != self.page_id
                || (!self.on_page() && images != self.images_space))
        {
            self.follow(engine);
            return;
        }
        let running = self.page_agent_running(engine);
        if std::mem::replace(&mut self.page_running, running) != running {
            self.publish(engine);
        }
    }

    fn page_agent_running(&self, engine: &Engine) -> bool {
        if !self.on_page() {
            return false;
        }
        let page = self.page_id.clone();
        controller::with::<Space, _>(engine, |s, e| {
            if s.page_id() != page {
                return false;
            }
            let status = field(&s.agent(e), "status").to_owned();
            status == "running" || status == "stopping"
        })
        .unwrap_or(self.page_running)
    }

    /// Asks the MC which project a page's ask would run in.
    fn ask_page_project(&mut self, engine: &Engine) {
        if !self.mc.is_ready() {
            return;
        }
        self.page_project_asked = true;
        let me = self.me.clone();
        let done: ProjectAnswer = Rc::new(move |engine, project| {
            later(&me, engine, move |c, e| {
                if c.page_project == project {
                    return;
                }
                c.page_project = project;
                c.publish(e);
            });
        });
        Bridge::of(engine).defer(engine, move |engine| {
            controller::with::<Space, _>(engine, |s, e| s.agent_target(e, done));
        });
    }

    /// The project a page's ask runs in: the one picked while it is still on
    /// the MC, else the one the MC says.
    pub(super) fn page_project(&self, engine: &Engine) -> String {
        let environment = self.mc.environment();
        if let Some(picked) = self.page_projects.get(&page_key(&self.page_id))
            && store::with(engine, |s| s.project_row(&environment, picked).is_some())
        {
            return picked.clone();
        }
        self.page_project.clone()
    }

    /// The model a page's ask starts on, as a new thread in its project
    /// would: this device's project override, the project's own, the
    /// default for new threads, then the model of the user's latest thread
    /// in the project whose provider can run it, then the model last sent
    /// with. None for any other target.
    pub(super) fn page_base_selection(&self, engine: &Engine, key: &str) -> Option<Obj> {
        if !self.on_page() || key != page_key(&self.page_id) {
            return None;
        }
        let environment = self.mc.environment();
        let project = self.page_project(engine);
        let settings = Settings::of(engine);
        let mut selection = settings
            .value(&format!(
                "projectSettingsOverrides.{project}.defaultModelSelection"
            ))
            .map(|v| as_object(&v).clone())
            .unwrap_or_default();
        if selection.is_empty() {
            selection = store::with(engine, |s| {
                s.project_row(&environment, &project)
                    .map(|row| {
                        as_object(row.get("defaultModelSelection").unwrap_or(&Json::Null)).clone()
                    })
                    .unwrap_or_default()
            });
        }
        if selection.is_empty() {
            selection = as_object(&setting(engine, "defaultModelSelection")).clone();
        }
        if selection.is_empty() && !project.is_empty() {
            let mut latest = String::new();
            for thread in store::with(engine, |s| s.threads()) {
                if thread.environment_id != environment
                    || thread.project_id != project
                    || thread.updated_at < latest
                {
                    continue;
                }
                if !self
                    .instance_of(&thread.model_selection)
                    .is_some_and(|i| i.ready())
                {
                    continue;
                }
                latest = thread.updated_at.clone();
                selection = thread.model_selection.clone();
            }
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
        Some(selection)
    }

    /// The permissions a page's ask starts in: its project's default, else
    /// the default for new threads. None for any other target.
    pub(super) fn page_runtime_mode(&self, engine: &Engine, target: &str) -> Option<String> {
        if !self.on_page() || target != page_key(&self.page_id) {
            return None;
        }
        let settings = Settings::of(engine);
        for path in [
            format!(
                "projectSettingsOverrides.{}.defaultRuntimeMode",
                self.page_project(engine)
            ),
            "defaultRuntimeMode".to_owned(),
        ] {
            if let Some(mode) = settings.value(&path).as_ref().and_then(Json::as_str)
                && !mode.is_empty()
            {
                return Some(mode.to_owned());
            }
        }
        Some("full-access".into())
    }

    /// The trigger at a page's caret: `/` picks a kind of block (SpacePage's
    /// menu) and the leading `@agent` is the ask, not a file.
    pub(super) fn page_trigger(
        &self,
        target: &str,
        text: &str,
        trigger: Trigger,
    ) -> Option<Trigger> {
        if !target.starts_with("page#") {
            return Some(trigger);
        }
        if trigger.kind == "slash-command" {
            return None;
        }
        let first = model::slice(text, 0, trigger.start).trim().is_empty();
        if trigger.kind == "path" && first && "agent".starts_with(&trigger.query.to_lowercase()) {
            return None;
        }
        Some(trigger)
    }

    /// Where a page's @ words are searched: the root of the project its ask
    /// runs in. None for any other target.
    pub(super) fn page_search_place(
        &self,
        engine: &Engine,
        target: &str,
    ) -> Option<(String, String)> {
        if !self.on_page() {
            return None;
        }
        if target != page_key(&self.page_id) {
            return Some((String::new(), String::new()));
        }
        let environment = self.mc.environment();
        let project = self.page_project(engine);
        let root = store::with(engine, |s| {
            s.project_row(&environment, &project)
                .map(|row| field(row, "workspaceRoot").to_owned())
                .unwrap_or_default()
        });
        Some((environment, root))
    }

    /// A page's ShellComposerState over the thread's: no provider is needed
    /// to write blocks, no queue or steering, and the project the ask runs
    /// in with the ones it could.
    pub(super) fn page_composer_state(&self, engine: &Engine, target: &str, state: &mut Json) {
        let environment = self.mc.environment();
        let offline = !store::with(engine, |s| s.environment_online(&environment));
        let busy = self.launching.contains(target);
        let kept = kept::draft_of(engine, target);
        let has_content = !string(state, "text").trim().is_empty() || kept.carries();
        let project_id = self.page_project(engine);
        let mut rows: Vec<(String, String)> = store::with(engine, |s| {
            s.project_rows(&environment)
                .into_iter()
                .map(|row| (field(row, "id").to_owned(), field(row, "title").to_owned()))
                .collect()
        });
        rows.sort();
        let mut project = Json::Null;
        let projects: Vec<Json> = rows
            .into_iter()
            .map(|(id, title)| {
                let entry = json!({"id": id, "title": title});
                if id == project_id {
                    project = entry.clone();
                }
                entry
            })
            .collect();
        let keymap = Keymap::of(engine);
        let send_shortcut = setting(engine, "sendShortcut");
        let sending = kept::read(engine, |d| d.queues.contains_key(target));
        state["routeKind"] = json!("page");
        // A page's agent runs in its project's own checkout.
        state["showContextStrip"] = json!(false);
        state["placeholder"] =
            json!("Write, type / for a kind of block, or @agent to ask an agent");
        state["canSend"] = json!(!(busy || offline) && has_content);
        state["sendDisabledReason"] = if offline {
            json!("Not connected")
        } else {
            Json::Null
        };
        state["isRunning"] = json!(self.page_running);
        // More words for a page's working agent go to its thread, so a page
        // has no queue or steering: its send button sends, or stops.
        state["followUpBehavior"] = json!("");
        state["enterIntents"] = model::enter_intents(
            &keymap.bindings(),
            keymap.mac(),
            send_shortcut.as_str().unwrap_or_default(),
            false,
            false,
        );
        state["isSendBusy"] = json!(busy || sending);
        state["pageId"] = json!(self.page_id);
        state["project"] = project;
        state["projects"] = Json::Array(projects);
    }

    /// A page's turn: its agent's requests are asked in the agent's thread.
    pub(super) fn page_turn_state(&self) -> Json {
        json!({
            "threadKey": "",
            "kind": "page",
            "running": false,
            "sending": self.launching.contains(&page_key(&self.page_id)),
            "approvals": [],
            "questions": [],
            "plan": null,
            "queue": [],
            "waiting": [],
            "queueHeld": false,
            "queueResuming": false,
        })
    }

    /// What the page's and the images' prompts do with an action, before a
    /// thread's composer would: None leaves it to the thread's.
    pub(super) fn handle_place(
        &mut self,
        engine: &Engine,
        action: &str,
        payload: &Json,
    ) -> Option<bool> {
        if self.on_images() {
            return self.handle_images(engine, action, payload);
        }
        match action {
            // A page has no terminal, diff or replies of its own to quote.
            "composer.terminalContext.add"
            | "composer.reviewComment.add"
            | "composer.citation.add"
                if self.on_page() =>
            {
                Some(true)
            }
            "composer.ask" => {
                self.start_ask(engine);
                Some(true)
            }
            "composer.project.set" => {
                let project = string(payload, "projectId");
                let environment = self.mc.environment();
                if self.on_page()
                    && store::with(engine, |s| s.project_row(&environment, &project).is_some())
                {
                    self.page_projects.insert(page_key(&self.page_id), project);
                    self.publish(engine);
                }
                Some(true)
            }
            "composer.interrupt" if self.on_page() => {
                Bridge::of(engine).defer(engine, |engine| {
                    controller::with::<Space, _>(engine, |s, e| {
                        s.handle(e, "space.agent.stop", &json!({}));
                    });
                });
                Some(true)
            }
            _ => None,
        }
    }

    /// The page's (or the images') send; None for a thread's or a draft's.
    pub(super) fn submit_place(
        &mut self,
        engine: &Engine,
        target: &str,
        text: &str,
    ) -> Option<bool> {
        if self.on_page() {
            return Some(self.submit_page(engine, target, text));
        }
        if self.on_images() {
            return Some(self.submit_images(engine, target, text));
        }
        None
    }

    fn submit_page(&mut self, engine: &Engine, target: &str, text: &str) -> bool {
        let trimmed = text.trim().to_owned();
        let kept = kept::draft_of(engine, target);
        if !is_ask(&trimmed) {
            if !kept.attachments.is_empty() || !kept.excerpts.is_empty() {
                toast_error(
                    engine,
                    "Not written",
                    "Attachments go to an agent: start the prompt with @agent.",
                );
            } else if !trimmed.is_empty() {
                // The page writes the block, or picks a kind or a chart
                // (SpacePage).
                let payload = json!({"pageId": self.page_id, "text": trimmed});
                Bridge::of(engine).defer(engine, move |engine| {
                    Bridge::of(engine).send_to_bricks(engine, "space.prompt.write", &payload);
                });
            }
            return true;
        }
        if self.launching.contains(target) {
            return true;
        }
        let environment = self.mc.environment();
        if !self.mc.is_ready() || !store::with(engine, |s| s.environment_online(&environment)) {
            warn(engine, "Not connected: message not sent", RECONNECTING);
            return true;
        }
        if self.files_block(engine, &kept.attachments, "sending") {
            return true;
        }
        // What a turn's message would carry; the MC takes `@agent` off the
        // request.
        let mut message = Obj::new();
        message.insert("text".into(), json!(trimmed));
        text::with_excerpts(&mut message, &kept.excerpts);
        let mut attachments = image_records(&kept.attachments);
        attachments.extend(file_records(&kept.attachments));
        let selection = self.selection(engine, target);
        let mut ask = Obj::new();
        ask.insert("request".into(), json!(field(&message, "text")));
        ask.insert(
            "runtimeMode".into(),
            json!(self.runtime_mode_of(engine, target)),
        );
        ask.insert(
            "interactionMode".into(),
            json!(self.interaction_mode_of(engine, target)),
        );
        let project = self.page_project(engine);
        if !project.is_empty() {
            ask.insert("projectId".into(), json!(project));
        }
        if !selection.is_empty() {
            ask.insert("modelSelection".into(), Json::Object(selection.clone()));
        }
        if !attachments.is_empty() {
            ask.insert("attachments".into(), Json::Array(attachments));
        }
        if let Some(context) = message.get("context") {
            ask.insert("context".into(), context.clone());
        }
        self.remember_model(engine, &selection);
        self.launching.insert(target.to_owned());
        self.publish(engine);
        let sent: Vec<String> = kept
            .attachments
            .iter()
            .map(|a| a.id.clone())
            .chain(kept.excerpts.iter().map(|e| e.id.clone()))
            .collect();
        // The prompt keeps what it asked until the MC takes it: a refusal
        // leaves every word and attachment there to try again.
        let me = self.me.clone();
        let (key, words) = (target.to_owned(), text.to_owned());
        let answered: Answer = Rc::new(move |engine, taken| {
            let (key, words, sent) = (key.clone(), words.clone(), sent.clone());
            later(&me, engine, move |c, e| {
                c.launching.remove(&key);
                if taken {
                    kept::edit_draft(e, &key, |draft| {
                        draft.attachments.retain(|a| !sent.contains(&a.id));
                        draft.excerpts.retain(|x| !sent.contains(&x.id));
                    });
                    if kept::draft(e, &key) == words {
                        c.set_text_end(e, &key, "");
                    } else {
                        kept::save(e);
                    }
                }
                c.publish(e);
            });
        });
        let page = self.page_id.clone();
        Bridge::of(engine).defer(engine, move |engine| {
            controller::with::<Space, _>(engine, |s, e| s.ask_agent(e, &page, ask, Some(answered)));
        });
        true
    }

    /// Starts an ask on the page: `@agent ` before what was written, and
    /// the keyboard in the prompt.
    pub(super) fn start_ask(&mut self, engine: &Engine) {
        let target = self.target(engine);
        if !self.on_page() || target.is_empty() {
            return;
        }
        let words = kept::draft(engine, &target);
        if !is_ask(&words) {
            self.set_text_end(engine, &target, &format!("@agent {words}"));
        }
        Bridge::of(engine).defer(engine, |engine| {
            Bridge::of(engine).send_to_bricks(engine, "composer.focus", &Json::Null);
        });
    }
}
