//! The composer on a Space's images (desktop-qt's ComposerController with
//! `onImages()`): with no thread, draft or page on show, the images' prompt,
//! keyed [`images_key`], makes an image of its words (`image.generate`
//! through the Space) with an image model the MC offers
//! (`space.image.providers`). Nothing a turn carries goes with it.

use std::rc::Rc;

use ljos::prelude::Engine;
use serde_json::json;

use super::{Composer, kept, later, setting, string};
use crate::composer_model::{self as model, Instance};
use crate::controller;
use crate::controllers::keybindings::Keymap;
use crate::controllers::space::Space;
use crate::controllers::toasts::{DEFAULT_TIMEOUT_MS, Toasts};
use crate::json::Json;
use crate::store;
use crate::thread_view::summary::{Obj, as_object, text as field};

/// Told whether the MC made the image.
type Answer = Rc<dyn Fn(&Engine, bool)>;

/// The images' prompt of the Space `space_id`.
pub(super) fn images_key(space_id: &str) -> String {
    format!("images#{space_id}")
}

fn or_null(value: &str) -> Json {
    if value.is_empty() {
        Json::Null
    } else {
        json!(value)
    }
}

fn providers(offer: &Obj) -> Vec<Obj> {
    offer
        .get("providers")
        .and_then(Json::as_array)
        .map(|list| list.iter().map(|p| as_object(p).clone()).collect())
        .unwrap_or_default()
}

/// Whether the MC's image offer has `model` on a ready `instance_id`.
fn offers_image_model(offer: &Obj, instance_id: &str, model: &str) -> bool {
    providers(offer).iter().any(|provider| {
        field(provider, "instanceId") == instance_id
            && field(provider, "status") == "ready"
            && provider
                .get("models")
                .and_then(Json::as_array)
                .is_some_and(|models| models.iter().any(|m| field(as_object(m), "slug") == model))
    })
}

/// The picker's instances for the images' prompt: each provider that can
/// make an image, drawn as the chat's picker draws it, with its image models.
fn image_picker_instances(offer: &Obj, catalogue: &[Instance]) -> Vec<Json> {
    providers(offer)
        .iter()
        .map(|provider| {
            let id = field(provider, "instanceId");
            let ready = field(provider, "status") == "ready";
            let message = field(provider, "message");
            let known = model::find(catalogue, id);
            let name = known
                .map(|k| k.display_name.as_str())
                .filter(|n| !n.is_empty())
                .unwrap_or(id);
            let models: Vec<Json> = provider
                .get("models")
                .and_then(Json::as_array)
                .into_iter()
                .flatten()
                .map(|entry| {
                    let entry = as_object(entry);
                    let slug = field(entry, "slug");
                    let shown = field(entry, "name");
                    json!({
                        "slug": slug,
                        "name": if shown.is_empty() { slug } else { shown },
                        "shortName": null,
                        "subProvider": null,
                        "isFavorite": false,
                        "isCustom": false,
                        "isNew": false,
                        "isLegacy": false,
                        "isUnavailable": !ready,
                        "disabledReason": if ready { Json::Null } else { or_null(message) },
                    })
                })
                .collect();
            json!({
                "instanceId": id,
                "driverKind": known.map_or_else(|| field(provider, "driver").to_owned(), |k| k.driver.clone()),
                "displayName": name,
                "accentColor": or_null(known.map_or("", |k| k.accent_color.as_str())),
                "iconUrl": or_null(known.map_or("", |k| k.icon_url.as_str())),
                "initials": model::initials_of(name),
                "showBadge": false,
                "status": if ready { "ready" } else { "error" },
                "isAvailable": ready,
                "unavailableReason": if ready { Json::Null } else { or_null(message) },
                "models": models,
            })
        })
        .collect()
}

fn offer(engine: &Engine) -> Obj {
    controller::with::<Space, _>(engine, |s, _| s.image_providers()).unwrap_or_default()
}

fn generating(engine: &Engine) -> bool {
    controller::with::<Space, _>(engine, |s, _| s.generating_image()).unwrap_or(false)
}

impl Composer {
    pub(super) fn on_images(&self) -> bool {
        !self.images_space.is_empty()
    }

    /// The image model `target` makes with: the one picked while the MC
    /// still offers it, else the offer's own.
    fn image_selection(&self, engine: &Engine, target: &str) -> Obj {
        let offer = offer(engine);
        if let Some(picked) = kept::read(engine, |d| {
            d.drafts.get(target).and_then(|k| k.model_selection.clone())
        }) && offers_image_model(
            &offer,
            field(&picked, "instanceId"),
            field(&picked, "model"),
        ) {
            return picked;
        }
        as_object(offer.get("selection").unwrap_or(&Json::Null)).clone()
    }

    fn select_image_model(
        &mut self,
        engine: &Engine,
        target: &str,
        instance_id: &str,
        model: &str,
    ) {
        if target.is_empty() || !offers_image_model(&offer(engine), instance_id, model) {
            return;
        }
        let selection = json!({"instanceId": instance_id, "model": model});
        kept::edit_draft(engine, target, |k| {
            k.model_selection = Some(as_object(&selection).clone());
        });
        kept::save(engine);
        self.publish(engine);
    }

    /// What the images' prompt does with an action: nothing a turn carries.
    pub(super) fn handle_images(
        &mut self,
        engine: &Engine,
        action: &str,
        payload: &Json,
    ) -> Option<bool> {
        match action {
            "composer.terminalContext.add"
            | "composer.reviewComment.add"
            | "composer.citation.add"
            | "composer.ask"
            | "composer.project.set"
            | "composer.model.multiple.toggle"
            | "composer.option.set"
            | "composer.runtimeMode.set"
            | "composer.interactionMode.set"
            | "composer.stash"
            | "composer.stash.restore"
            | "composer.interrupt"
            | "composer.attach"
            | "composer.plan.implement"
            | "composer.model.favorite.toggle" => Some(true),
            "composer.model.select" => {
                let target = self.target(engine);
                self.select_image_model(
                    engine,
                    &target,
                    &string(payload, "instanceId"),
                    &string(payload, "model"),
                );
                Some(true)
            }
            _ => None,
        }
    }

    pub(super) fn submit_images(&mut self, engine: &Engine, target: &str, text: &str) -> bool {
        let prompt = text.trim().to_owned();
        if prompt.is_empty() || generating(engine) {
            return true;
        }
        let environment = self.mc.environment();
        if !self.mc.is_ready() || !store::with(engine, |s| s.environment_online(&environment)) {
            controller::with::<Toasts, _>(engine, |t, e| {
                t.show(
                    e,
                    "warning",
                    "Not connected: no image made",
                    "Reconnecting to the environment. Try again once it is connected.",
                    None,
                    DEFAULT_TIMEOUT_MS,
                );
            });
            return true;
        }
        // The prompt keeps its words until the image is made: a refusal or a
        // failed generation leaves them there to try again.
        let selection = self.image_selection(engine, target);
        let me = self.me.clone();
        let (key, words) = (target.to_owned(), text.to_owned());
        let answered: Answer = Rc::new(move |engine, made| {
            let (key, words) = (key.clone(), words.clone());
            later(&me, engine, move |c, e| {
                if made && kept::draft(e, &key) == words {
                    c.set_text(e, &key, "", 0, &Json::Null);
                }
                c.publish(e);
            });
        });
        crate::bridge::Bridge::of(engine).defer(engine, move |engine| {
            controller::with::<Space, _>(engine, |s, e| {
                s.generate_image(e, &prompt, selection, Some(answered));
            });
        });
        true
    }

    /// The images' turn: an image being made is the only work.
    pub(super) fn images_turn_state(&self, engine: &Engine) -> Json {
        json!({
            "threadKey": "",
            "kind": "images",
            "running": false,
            "sending": generating(engine),
            "approvals": [],
            "questions": [],
            "plan": null,
            "queue": [],
            "waiting": [],
            "queueHeld": false,
            "queueResuming": false,
        })
    }

    /// The picker's instances on the images, else None.
    pub(super) fn images_picker_instances(&self, engine: &Engine) -> Option<Vec<Json>> {
        self.on_images()
            .then(|| image_picker_instances(&offer(engine), &self.catalogue))
    }

    /// The images' ShellComposerState: a prompt and an image model, nothing
    /// a turn carries.
    pub(super) fn images_composer_state(&self, engine: &Engine) -> Json {
        let target = images_key(&self.images_space);
        let kept = kept::draft_of(engine, &target);
        let text = kept::draft(engine, &target);
        let offer = offer(engine);
        let answered = !offer.is_empty();
        let able = providers(&offer)
            .iter()
            .any(|p| field(p, "status") == "ready");
        let busy = generating(engine);
        let environment = self.mc.environment();
        let offline = !store::with(engine, |s| s.environment_online(&environment));
        let chosen = self.image_selection(engine, &target);
        let disabled_reason = if offline {
            json!("Not connected")
        } else if answered && !able {
            json!("No provider can generate images")
        } else {
            Json::Null
        };
        let keymap = Keymap::of(engine);
        let send_shortcut = setting(engine, "sendShortcut");
        json!({
            "target": target,
            "routeKind": "images",
            "spaceId": self.images_space,
            "showContextStrip": false,
            "edit": kept.edit,
            "text": text,
            "cursor": kept.cursor.clamp(0, model::utf16_len(&text) as i64),
            "triggerKind": null,
            "suggestions": [],
            "suggestionsEmptyText": null,
            "attachments": [],
            "terminalContexts": [],
            "reviewComments": [],
            "threadContexts": [],
            "citations": [],
            "placeholder": if answered && !able {
                "No provider here can generate images. Set up Codex or Grok in Settings."
            } else {
                "What should the image show?"
            },
            "editorDisabled": false,
            "canSend": !(busy || offline) && able && !text.trim().is_empty(),
            "sendDisabledReason": disabled_reason,
            "isRunning": false,
            "followUpBehavior": "",
            "canSteer": true,
            "enterIntents": model::enter_intents(
                &keymap.bindings(),
                keymap.mac(),
                send_shortcut.as_str().unwrap_or_default(),
                false,
                false,
            ),
            "isSendBusy": busy,
            "isConnecting": false,
            "pendingApprovalCount": 0,
            "pendingUserInputCount": 0,
            "showPlanFollowUpPrompt": false,
            "selectedInstanceId": or_null(field(&chosen, "instanceId")),
            "selectedModel": or_null(field(&chosen, "model")),
            "options": [],
            "runtimeMode": "",
            "defaultRuntimeMode": "",
            "runtimeModes": [],
            "interactionMode": "default",
            "showInteractionModeToggle": false,
            "usageLimits": null,
            "editingQueuedRunId": null,
        })
    }
}
