//! JSON in and out of QML values: what the controllers speak (it is what
//! the MC sends) and what `Shell.state` and `Shell.dispatch` carry.
//!
//! How a controller passes JSON (Ljós's records and typed collections):
//!
//! - A method QML calls with data takes it typed: `payload: Json`,
//!   `keys: Vec<String>`. Ljós copies the script's object as it arrives.
//! - A method's one-off answer is returned typed: `-> Vec<String>`, `-> Json`.
//! - State QML binds to (a property, `Shell.state`, a signal argument) goes
//!   through [`to_value`], as one script object. Ljós makes a typed value
//!   (a `Value::Map`) into a new object on every read, which costs a copy of
//!   the whole tree per read and breaks `===`. TODO(ljos#47).
//! - A `var` is read with [`from_value`]: a `var` property, and the payloads
//!   of `Shell.dispatch` and `Shell.publish`. Those come from hundreds of
//!   call sites, and a typed `Json` parameter throws the whole call for one
//!   field that is not data (a function, a QML object), where this reads
//!   the rest. TODO(ljos#48).

use std::cell::OnceCell;

use ljos::prelude::{Engine, QmlValue, Value};

pub type Json = serde_json::Value;

/// `json` as QML sees it: one JS object or array (made once, so reads share
/// it), or a string, number, bool or null.
pub fn to_value(engine: &Engine, json: &Json) -> Value {
    let value = json.to_value();
    if !matches!(json, Json::Array(_) | Json::Object(_)) {
        return value;
    }
    // A script's own object is what a script function returns: handing the
    // record through one makes it that object.
    let identity = engine.extension::<Identity>();
    let identity = identity.0.get_or_init(|| {
        engine
            .eval_js("(function (v) { return v })")
            .unwrap_or_default()
    });
    engine.call_js(identity, &[value]).unwrap_or_default()
}

#[derive(Default)]
struct Identity(OnceCell<Value>);

/// What QML passed, as JSON: `undefined` is `null`, as is a function. A
/// payload holding something JSON has no word for (a QML object) is read as
/// `JSON.stringify` writes it; the bricks never send one.
pub fn from_value(engine: &Engine, value: &Value) -> Json {
    Json::from_value(&engine.deep_copy(value)).unwrap_or_else(|_| stringified(engine, value))
}

fn stringified(engine: &Engine, value: &Value) -> Json {
    let text = engine
        .eval_js("JSON.stringify")
        .ok()
        .and_then(|stringify| engine.call_js(&stringify, std::slice::from_ref(value)));
    match text {
        Some(Value::String(s)) => serde_json::from_str(&s).unwrap_or(Json::Null),
        _ => Json::Null,
    }
}
