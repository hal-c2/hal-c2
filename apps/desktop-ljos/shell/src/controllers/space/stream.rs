//! One stream of a Space as the MC sends it, desktop-qt's SpaceStream:
//! its entities by kind and id, and where a `sub` resumes. A snapshot
//! replaces the copy once its last part lands; events apply HalC2.Patch in
//! log order and skip what the copy already holds; a catch-up split over
//! frames is applied as one.

use std::collections::HashMap;

use serde_json::{Map, Value, json};

use crate::json::Json;
use crate::mc::Frame;

pub type Entity = Map<String, Value>;

/// HalC2.Patch: `s` sets, `u` unsets, `a` appends to strings, `d` deletes
/// (alone) or replaces (with `s`/`a`). None when the entity is gone.
fn patched(entity: &Entity, patch: &Entity) -> Option<Entity> {
    let replace = patch.get("d").and_then(Value::as_bool).unwrap_or(false);
    if replace && !patch.contains_key("s") && !patch.contains_key("a") {
        return None;
    }
    let mut next = if replace {
        Entity::new()
    } else {
        entity.clone()
    };
    if let Some(set) = patch.get("s").and_then(Value::as_object) {
        for (k, v) in set {
            next.insert(k.clone(), v.clone());
        }
    }
    if let Some(unset) = patch.get("u").and_then(Value::as_array) {
        for field in unset {
            if let Some(field) = field.as_str() {
                next.remove(field);
            }
        }
    }
    if let Some(append) = patch.get("a").and_then(Value::as_object) {
        for (k, v) in append {
            let was = next.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
            next.insert(
                k.clone(),
                json!(format!("{}{}", was, v.as_str().unwrap_or(""))),
            );
        }
    }
    Some(next)
}

fn int(value: Option<&Value>) -> i64 {
    value
        .and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)))
        .unwrap_or(-1)
}

#[derive(Default)]
pub struct SpaceStream {
    entities: HashMap<String, HashMap<String, Entity>>,
    incoming: HashMap<String, HashMap<String, Entity>>,
    catch_up: Vec<Value>,
    offset: i64,
    handle: String,
    catching_up: bool,
    live: bool,
}

impl SpaceStream {
    pub fn new() -> SpaceStream {
        SpaceStream {
            offset: -1,
            ..SpaceStream::default()
        }
    }

    /// The `sub` resume: no offset without a copy, else its offset and
    /// handle. Starts a catch-up.
    pub fn subscribing(&mut self) -> Json {
        self.catching_up = true;
        self.live = false;
        self.catch_up.clear();
        self.incoming.clear();
        if self.offset < 0 {
            return json!({"offset": null});
        }
        let mut resume = json!({"offset": self.offset});
        if !self.handle.is_empty() {
            resume["handle"] = json!(self.handle);
        }
        resume
    }

    /// Applies a frame; true when an entity changed.
    pub fn receive(&mut self, frame: &Frame) -> bool {
        let kind = frame.get("t").and_then(Value::as_str).unwrap_or("");
        let reached = int(frame.get("offset"));
        match kind {
            "snapshot" => {
                if frame.get("part").and_then(Value::as_i64).unwrap_or(0) == 0 {
                    self.incoming.clear();
                }
                if let Some(rows) = frame.get("rows").and_then(Value::as_array) {
                    for row in rows {
                        let Some(row) = row.as_array() else { continue };
                        if row.len() < 3 {
                            continue;
                        }
                        let (Some(k), Some(id), Some(entity)) =
                            (row[0].as_str(), row[1].as_str(), row[2].as_object())
                        else {
                            continue;
                        };
                        self.incoming
                            .entry(k.to_owned())
                            .or_default()
                            .insert(id.to_owned(), entity.clone());
                    }
                }
                if frame.get("done").and_then(Value::as_bool) != Some(true) {
                    return false;
                }
                self.entities = std::mem::take(&mut self.incoming);
                self.catch_up.clear();
                self.offset = reached.max(0);
                self.handle = frame
                    .get("handle")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned();
                true
            }
            "events" => {
                if let Some(events) = frame.get("events").and_then(Value::as_array) {
                    self.catch_up.extend(events.iter().cloned());
                }
                if self.catching_up && reached >= 0 && reached <= self.offset {
                    return false;
                }
                let all = std::mem::take(&mut self.catch_up);
                let changed = self.events(&all);
                if self.offset >= 0 && reached > self.offset {
                    self.offset = reached;
                }
                changed
            }
            "live" => {
                self.catching_up = false;
                let mut changed = !self.live;
                if !self.catch_up.is_empty() {
                    let all = std::mem::take(&mut self.catch_up);
                    changed = self.events(&all) || changed;
                }
                if self.offset >= 0 && reached > self.offset {
                    self.offset = reached;
                }
                let handle = frame.get("handle").and_then(Value::as_str).unwrap_or("");
                if !handle.is_empty() {
                    self.handle = handle.to_owned();
                }
                self.live = true;
                changed
            }
            "resync" => {
                if self.offset >= 0 && reached > self.offset {
                    self.offset = reached;
                }
                false
            }
            _ => false,
        }
    }

    fn events(&mut self, events: &[Value]) -> bool {
        let mut changed = false;
        for value in events {
            let Some(event) = value.as_array() else {
                continue;
            };
            if event.len() < 4 {
                continue;
            }
            // One the copy holds already (a frame sent again on a reconnect).
            if self.offset >= 0 && event[0].is_number() && int(Some(&event[0])) <= self.offset {
                continue;
            }
            let (Some(kind), Some(id), Some(patch)) =
                (event[1].as_str(), event[2].as_str(), event[3].as_object())
            else {
                continue;
            };
            let entities = self.entities.entry(kind.to_owned()).or_default();
            let current = entities.get(id).cloned().unwrap_or_default();
            match patched(&current, patch) {
                Some(next) => {
                    entities.insert(id.to_owned(), next);
                }
                None => {
                    entities.remove(id);
                }
            }
            changed = true;
        }
        changed
    }

    pub fn clear(&mut self) {
        *self = SpaceStream::new();
    }

    pub fn live(&self) -> bool {
        self.live
    }

    pub fn has_copy(&self) -> bool {
        self.offset >= 0
    }

    pub fn offset(&self) -> i64 {
        self.offset
    }

    pub fn of(&self, kind: &str) -> &HashMap<String, Entity> {
        static NONE: std::sync::OnceLock<HashMap<String, Entity>> = std::sync::OnceLock::new();
        self.entities
            .get(kind)
            .unwrap_or_else(|| NONE.get_or_init(HashMap::new))
    }

    pub fn entity(&self, kind: &str, id: &str) -> Entity {
        self.of(kind).get(id).cloned().unwrap_or_default()
    }

    pub fn has(&self, kind: &str, id: &str) -> bool {
        self.of(kind).contains_key(id)
    }
}

/// A text field of an entity, "" for none or for null.
pub fn text(entity: &Entity, field: &str) -> String {
    entity
        .get(field)
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned()
}

/// In the order the MC keeps them: by `field`, then id.
pub fn sorted(mut entities: Vec<Entity>, field: &str) -> Vec<Entity> {
    entities.sort_by(|a, b| {
        text(a, field)
            .cmp(&text(b, field))
            .then_with(|| text(a, "id").cmp(&text(b, "id")))
    });
    entities
}
