//! What the settings pages' controllers share: which page the route shows,
//! and QVariant's reading of a payload's loosely typed values.

use crate::json::Json;

/// Whether `route` (the published `route`) shows Settings → General, which
/// is also bare `/settings`.
pub fn general_open(route: &Json) -> bool {
    shows(route, &["", "/settings", "/settings/general"])
}

/// Whether `route` is Settings at one of `sections` ("" is the first).
pub fn shows(route: &Json, sections: &[&str]) -> bool {
    route.get("kind").and_then(Json::as_str) == Some("settings")
        && sections.contains(&section(route))
}

/// The settings section `route` names, empty for none.
pub fn section(route: &Json) -> &str {
    route
        .get("section")
        .and_then(Json::as_str)
        .unwrap_or_default()
}

/// A payload's text, empty when it is not text.
pub fn text<'a>(payload: &'a Json, key: &str) -> &'a str {
    payload.get(key).and_then(Json::as_str).unwrap_or_default()
}

/// `QVariant::toInt`: a number rounds, a string that reads as one is it,
/// anything else is 0.
pub fn int(value: Option<&Json>) -> i64 {
    match value {
        Some(Json::Number(n)) => n.as_f64().map_or(0, |f| f.round() as i64),
        Some(Json::String(s)) => s.trim().parse::<f64>().map_or(0, |f| f.round() as i64),
        Some(Json::Bool(b)) => i64::from(*b),
        _ => 0,
    }
}

/// `QVariant::toBool`: numbers are true unless zero, text unless empty,
/// "0" or "false"; null is false.
pub fn flag(value: Option<&Json>) -> bool {
    match value {
        Some(Json::Bool(b)) => *b,
        Some(Json::Number(n)) => n.as_f64().is_some_and(|f| f != 0.0),
        Some(Json::String(s)) => !(s.is_empty() || s == "0" || s.eq_ignore_ascii_case("false")),
        _ => false,
    }
}
