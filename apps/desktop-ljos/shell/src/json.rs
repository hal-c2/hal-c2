//! JSON in and out of QML values: what the controllers speak (it is what
//! the MC sends) and what `Shell.state` and `Shell.dispatch` carry.
//!
//! Ljós has no map value and no conversion between its `Value` and a JS
//! object, so both directions go through the engine's own `JSON`: one
//! `JSON.parse` per publish, one `JSON.stringify` per dispatched payload.
//! QML objects in a payload (an `Item`) do not survive; the bricks never
//! send one.

use ljos::prelude::{Engine, Value};

pub type Json = serde_json::Value;

/// `json` as QML sees it: a JS object, array, string, number, bool or null.
pub fn to_value(engine: &Engine, json: &Json) -> Value {
    match json {
        Json::Null => Value::Null,
        Json::Bool(b) => Value::Bool(*b),
        Json::Number(n) => Value::Real(n.as_f64().unwrap_or(0.0)),
        Json::String(s) => Value::from(s.as_str()),
        Json::Array(_) | Json::Object(_) => {
            // A JSON text is a JS string literal of itself.
            let literal = serde_json::to_string(&json.to_string()).unwrap_or_default();
            engine
                .eval_js(&format!("JSON.parse({literal})"))
                .unwrap_or(Value::Undefined)
        }
    }
}

/// What QML passed, as JSON. `undefined` and anything JSON has no word for
/// (a function, a QML object) is `null`.
pub fn from_value(engine: &Engine, value: &Value) -> Json {
    match value {
        Value::Undefined | Value::Null => Json::Null,
        Value::Bool(b) => Json::Bool(*b),
        Value::Int(i) => Json::from(*i),
        Value::Real(r) => serde_json::Number::from_f64(*r).map_or(Json::Null, Json::Number),
        Value::String(s) | Value::Url(s) => Json::String(s.to_string()),
        Value::Js(_) | Value::List(_) => {
            let text = engine
                .eval_js("JSON.stringify")
                .ok()
                .and_then(|stringify| engine.call_js(&stringify, std::slice::from_ref(value)));
            match text {
                Some(Value::String(s)) => serde_json::from_str(&s).unwrap_or(Json::Null),
                _ => Json::Null,
            }
        }
        other => Json::String(engine.to_js_string(other).to_string()),
    }
}
