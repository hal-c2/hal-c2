//! `mermaid`, desktop-qt's MermaidController: Mermaid diagrams, drawn by
//! the MC (`mermaid.render`, packages/contracts mermaid.ts) and kept here
//! by theme and source, so a block scrolled back into view, laid out
//! again or shown in another window is not asked for twice.
//!
//! QML reads them through the `Diagrams` singleton
//! (Bricks/MermaidDiagram.qml): diagram(source, theme) answers at once
//! with what is known, {status: "drawing"} while the MC is asked, then
//! {status: "drawn", kind, url (a data: URL of the SVG), width, height}
//! or {status: "unsupported" | "invalid" | "failed", kind, reason,
//! line?, column?}; `revision` changes with every answer, so a binding
//! that reads it asks again. Drawn, unsupported and invalid answers are
//! kept; a failed one (the MC could not draw it, or could not be
//! reached) is asked again by retry() and once the MC is back. Past 256
//! answers the oldest go, never one a block has read since the last
//! answer.

use std::collections::HashMap;
use std::rc::Rc;

use base64::Engine as _;
use ljos::prelude::{Atom, Cx, Engine, QmlObject, QmlValue, Value, qml_impl, qml_singleton};
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init, Me};
use crate::json::Json;
use crate::mc::{Mc, McError};

const KEPT: usize = 256;

fn key_of(source: &str, theme: &str) -> String {
    format!("{theme}\n{source}")
}

fn text_of<'a>(object: &'a Json, key: &str) -> &'a str {
    object.get(key).and_then(Json::as_str).unwrap_or_default()
}

struct Entry {
    source: String,
    theme: String,
    answer: Json,
    pending: bool,
    request: i32,
    // The revision it was last read in: one read in this one is on screen.
    seen: i32,
}

pub struct Mermaid {
    mc: Rc<dyn Mc>,
    me: Me<Mermaid>,
    entries: HashMap<String, Entry>,
    // Keys, oldest first.
    order: Vec<String>,
    revision: i32,
    next_request: i32,
}

impl Controller for Mermaid {
    fn new(init: Init<'_, Self>) -> Self {
        let me = init.me.clone();
        init.mc.on_ready_changed(Box::new(move |engine, ready| {
            if ready {
                me.run(engine, |mermaid, engine| mermaid.reconnected(engine));
            }
        }));
        Mermaid {
            mc: init.mc,
            me: init.me,
            entries: HashMap::new(),
            order: Vec::new(),
            revision: 0,
            next_request: 1,
        }
    }
}

impl Mermaid {
    pub fn diagram(&mut self, source: &str, theme: &str) -> Json {
        let key = key_of(source, theme);
        if let Some(entry) = self.entries.get_mut(&key) {
            entry.seen = self.revision;
            return if entry.pending {
                json!({"status": "drawing"})
            } else {
                entry.answer.clone()
            };
        }
        self.entries.insert(
            key.clone(),
            Entry {
                source: source.to_owned(),
                theme: theme.to_owned(),
                answer: Json::Null,
                pending: false,
                request: 0,
                seen: self.revision,
            },
        );
        self.order.push(key.clone());
        // Room for this one: the oldest answers go, never one still being
        // asked for or one read since the last answer. That one is on
        // screen, and dropping it would ask for it again at once, and its
        // answer would push out the next.
        let mut i = 0;
        while self.order.len() > KEPT && i < self.order.len() {
            let spare = self
                .entries
                .get(&self.order[i])
                .is_some_and(|entry| !entry.pending && entry.seen != self.revision);
            if spare {
                let gone = self.order.remove(i);
                self.entries.remove(&gone);
            } else {
                i += 1;
            }
        }
        self.ask(&key);
        json!({"status": "drawing"})
    }

    pub fn retry(&mut self, engine: &Engine, source: &str, theme: &str) {
        let key = key_of(source, theme);
        let Some(entry) = self.entries.get(&key) else {
            return;
        };
        if entry.pending || text_of(&entry.answer, "status") != "failed" {
            return;
        }
        self.ask(&key);
        self.bump(engine);
    }

    fn reconnected(&mut self, engine: &Engine) {
        let failed: Vec<String> = self
            .order
            .iter()
            .filter(|key| {
                self.entries.get(*key).is_some_and(|entry| {
                    !entry.pending && text_of(&entry.answer, "status") == "failed"
                })
            })
            .cloned()
            .collect();
        if failed.is_empty() {
            return;
        }
        for key in &failed {
            self.ask(key);
        }
        self.bump(engine);
    }

    fn ask(&mut self, key: &str) {
        let request = self.next_request;
        self.next_request += 1;
        let (source, theme) = {
            let Some(entry) = self.entries.get_mut(key) else {
                return;
            };
            entry.pending = true;
            entry.request = request;
            (entry.source.clone(), entry.theme.clone())
        };
        let me = self.me.clone();
        let key = key.to_owned();
        self.mc.call(
            &self.mc.environment(),
            "mermaid.render",
            json!({"source": source, "format": "svg", "theme": theme}),
            Box::new(move |engine: &Engine, result| {
                me.run(engine, |mermaid, engine| {
                    mermaid.answered(engine, &key, request, result);
                });
            }),
        );
    }

    fn answered(
        &mut self,
        engine: &Engine,
        key: &str,
        request: i32,
        result: Result<Json, McError>,
    ) {
        // Gone to make room, or asked again since.
        if self
            .entries
            .get(key)
            .is_none_or(|entry| entry.request != request)
        {
            return;
        }
        let shown = match &result {
            Err(error) => {
                let away = matches!(error.message.as_str(), "not connected" | "disconnected");
                json!({"status": "failed",
                "reason": if away {
                    "The MC could not be reached to draw this diagram."
                } else {
                    error.message.as_str()
                }})
            }
            Ok(answer) => {
                let status = text_of(answer, "status");
                if status == "drawn"
                    && let Some(svg) = answer.get("svg").and_then(Json::as_str)
                {
                    // Kept as the data: URL an Image loads, so a block shown
                    // again costs nothing.
                    json!({"status": "drawn",
                           "kind": text_of(answer, "kind"),
                           "url": format!(
                               "data:image/svg+xml;base64,{}",
                               base64::engine::general_purpose::STANDARD.encode(svg)
                           ),
                           "width": answer.get("width").and_then(Json::as_f64).unwrap_or(0.0),
                           "height": answer.get("height").and_then(Json::as_f64).unwrap_or(0.0)})
                } else if matches!(status, "unsupported" | "invalid" | "failed") {
                    let mut shown = json!({"status": status,
                                           "kind": text_of(answer, "kind"),
                                           "reason": text_of(answer, "reason")});
                    // Where the mistake is, when the renderer says (null
                    // otherwise).
                    for field in ["line", "column"] {
                        if let Some(at) = answer.get(field).and_then(Json::as_i64) {
                            shown[field] = json!(at);
                        }
                    }
                    shown
                } else {
                    json!({"status": "failed",
                           "reason": "The MC answered with no diagram."})
                }
            }
        };
        let Some(entry) = self.entries.get_mut(key) else {
            return;
        };
        entry.answer = shown;
        entry.pending = false;
        self.bump(engine);
    }

    fn bump(&mut self, engine: &Engine) {
        self.revision += 1;
        let revision = self.revision;
        // Written once this controller has returned: the write runs the
        // bricks' bindings at once, and the diagram() they ask cannot
        // borrow the controller while it is still running.
        Bridge::of(engine).defer(engine, move |engine| {
            if let Ok(obj) = Bridge::of(engine).singleton::<DiagramsObject>(engine)
                && let Err(e) = engine.set_internal(obj, DiagramsObject::REVISION, revision)
            {
                engine.log(ljos::prelude::LogLevel::Warning, "Diagrams", e.to_string());
            }
        });
    }
}

/// `Diagrams` in QML: what the MC drew of a Mermaid block, by theme and
/// source.
#[derive(Debug, Default, QmlObject)]
#[qml(module = "HalC2.Shell", name = "Diagrams", uncreatable)]
#[qml_singleton]
pub struct DiagramsObject {
    /// Changes with every answer, so a binding that reads it asks again.
    #[qml(notify, readonly)]
    revision: i32,
}

#[qml_impl]
impl DiagramsObject {
    #[qml(invokable)]
    fn diagram(cx: &Cx, source: Atom, theme: Atom) -> Value {
        let answer = controller::with::<Mermaid, _>(cx.engine, |mermaid, _| {
            mermaid.diagram(&source, &theme)
        })
        .unwrap_or_else(|| json!({"status": "drawing"}));
        answer.to_value()
    }

    #[qml(invokable)]
    fn retry(cx: &Cx, source: Atom, theme: Atom) {
        controller::with::<Mermaid, _>(cx.engine, |mermaid, engine| {
            mermaid.retry(engine, &source, &theme);
        });
    }
}
