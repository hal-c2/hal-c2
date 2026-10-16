//! `menu` and `confirmation`, desktop-qt's MenuController: the shell's one
//! context menu and one confirmation question. A controller opens a menu of
//! [`Item`]s at window coordinates with what runs the chosen id
//! ([`Menus::open`]), or asks a question with what runs on yes
//! ([`Menus::confirm`]); the ContextMenuHost and ConfirmDialog bricks
//! render them.
//!
//! `menu` is `{requestId, surfaceId: "shell", x, y, items}`, each item `{id,
//! label, icon, enabled, checked, destructive, separatorBefore, children}`;
//! `menu.select {requestId, id}` picks (a null id dismisses).
//! `confirmation` is `{requestId, title, description, confirmLabel,
//! destructive}`; `confirmation.answer {requestId, accepted}` answers it. A
//! newer menu or question replaces the open one, which is then dismissed.

use std::rc::Rc;

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{Controller, Init};
use crate::json::Json;

/// What runs with the id picked; never on dismiss. It runs once no
/// controller is running, so it may open another menu.
pub type Chosen = Rc<dyn Fn(&Engine, &str)>;
pub type Answer = Rc<dyn Fn(&Engine)>;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Item {
    pub id: String,
    pub label: String,
    pub icon: String,
    pub enabled: bool,
    pub checked: bool,
    pub destructive: bool,
    pub separator_before: bool,
    pub children: Vec<Item>,
}

impl Item {
    /// An enabled item.
    pub fn new(id: impl Into<String>, label: impl Into<String>) -> Item {
        Item {
            id: id.into(),
            label: label.into(),
            enabled: true,
            ..Item::default()
        }
    }

    fn json(&self) -> Json {
        let mut entry = json!({
            "id": self.id,
            "label": self.label,
            "icon": self.icon,
            "enabled": self.enabled,
            "checked": self.checked,
            "destructive": self.destructive,
            "separatorBefore": self.separator_before,
        });
        if !self.children.is_empty() {
            entry["children"] = Json::Array(self.children.iter().map(Item::json).collect());
        }
        entry
    }
}

/// Whether `id` is an enabled leaf of `items`, or of an enabled item's
/// children.
fn offered(items: &[Item], id: &str) -> bool {
    items
        .iter()
        .filter(|i| i.enabled)
        .any(|item| (item.id == id && item.children.is_empty()) || offered(&item.children, id))
}

struct Open {
    request_id: String,
    items: Vec<Item>,
    chosen: Chosen,
}

struct Question {
    request_id: String,
    accepted: Option<Answer>,
    declined: Option<Answer>,
}

pub struct Menus {
    bridge: Bridge,
    next_id: u64,
    menu: Option<Open>,
    question: Option<Question>,
}

impl Controller for Menus {
    fn new(init: Init<'_, Self>) -> Self {
        Menus {
            bridge: init.bridge,
            next_id: 1,
            menu: None,
            question: None,
        }
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        let request_id = payload
            .get("requestId")
            .and_then(Json::as_str)
            .unwrap_or_default();
        match action {
            "menu.select" => {
                if self
                    .menu
                    .as_ref()
                    .is_none_or(|m| m.request_id != request_id)
                {
                    return true;
                }
                let Some(menu) = self.menu.take() else {
                    return true;
                };
                self.bridge.publish(engine, "menu", Json::Null);
                // Only what was offered can be picked, however the answer
                // is spelled.
                if let Some(id) = payload.get("id").and_then(Json::as_str)
                    && offered(&menu.items, id)
                {
                    let (chosen, id) = (menu.chosen, id.to_owned());
                    self.bridge.defer(engine, move |engine| chosen(engine, &id));
                }
                true
            }
            "confirmation.answer" => {
                if self
                    .question
                    .as_ref()
                    .is_none_or(|q| q.request_id != request_id)
                {
                    return true;
                }
                let Some(question) = self.question.take() else {
                    return true;
                };
                self.bridge.publish(engine, "confirmation", Json::Null);
                let accepted = payload
                    .get("accepted")
                    .and_then(Json::as_bool)
                    .unwrap_or(false);
                let answer = if accepted {
                    question.accepted
                } else {
                    question.declined
                };
                if let Some(answer) = answer {
                    self.bridge.defer(engine, move |engine| answer(engine));
                }
                true
            }
            _ => false,
        }
    }
}

impl Menus {
    /// Shows `items` at (`x`, `y`); `chosen` runs with the id picked, never
    /// on dismiss. Returns the request id.
    pub fn open(
        &mut self,
        engine: &Engine,
        x: f64,
        y: f64,
        items: Vec<Item>,
        chosen: impl Fn(&Engine, &str) + 'static,
    ) -> String {
        let request_id = format!("menu:{}", self.next_id);
        self.next_id += 1;
        let shown: Vec<Json> = items.iter().map(Item::json).collect();
        self.menu = Some(Open {
            request_id: request_id.clone(),
            items,
            chosen: Rc::new(chosen),
        });
        self.bridge.publish(
            engine,
            "menu",
            json!({"requestId": request_id, "surfaceId": "shell", "x": x, "y": y, "items": shown}),
        );
        request_id
    }

    pub fn close(&mut self, engine: &Engine) {
        if self.menu.take().is_some() {
            self.bridge.publish(engine, "menu", Json::Null);
        }
    }

    pub fn is_open(&self) -> bool {
        self.menu.is_some()
    }

    /// Asks; `accepted` runs on yes only, `declined` (when given) on no.
    /// Returns the request id.
    pub fn confirm(
        &mut self,
        engine: &Engine,
        title: &str,
        description: &str,
        confirm_label: &str,
        destructive: bool,
        accepted: Option<Answer>,
        declined: Option<Answer>,
    ) -> String {
        let request_id = format!("confirm:{}", self.next_id);
        self.next_id += 1;
        self.question = Some(Question {
            request_id: request_id.clone(),
            accepted,
            declined,
        });
        self.bridge.publish(
            engine,
            "confirmation",
            json!({
                "requestId": request_id,
                "title": title,
                "description": description,
                "confirmLabel": confirm_label,
                "destructive": destructive,
            }),
        );
        request_id
    }
}
