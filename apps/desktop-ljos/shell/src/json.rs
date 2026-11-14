//! JSON as the controllers speak it: what the MC sends, and what
//! `Shell.state` and `Shell.dispatch` carry.
//!
//! How a controller passes JSON to and from QML:
//!
//! - A method QML calls with data takes it typed: `payload: Json`,
//!   `paths: Vec<String>`. Ljós reads what `JSON.stringify` would write: a
//!   function or `undefined` field is left out, and a QML object in it
//!   throws the call with the path to it. A `Vec` given nothing is empty.
//! - A property, `Shell.state` entry or signal argument QML reads is the
//!   value's `to_value()` (or a `Json` field). An object is one script
//!   object until it is set again, so reads share it and `===` holds; an
//!   array on its own is copied on each read, as Qt copies a list.
//! - A `var` is read with [`from_value`].

use ljos::prelude::{Engine, QmlValue, Value};

pub type Json = serde_json::Value;

/// What a `var` holds, as JSON: `null` for `undefined`, and for what JSON
/// has no word for (a QML object).
pub fn from_value(engine: &Engine, value: &Value) -> Json {
    Json::from_value(&engine.deep_copy(value)).unwrap_or(Json::Null)
}
