//! A project's actions as an environment's settings resolve them,
//! desktop-qt's `projectScripts`: the project's own list (its
//! `defaultProjectScripts` override), else the scripts its row carries, else
//! the environment's `defaultProjectScripts`.

use crate::json::Json;

/// The project's `defaultProjectScripts` override, if the settings hold one
/// (of any type).
pub fn override_of<'a>(settings: &'a Json, project_id: &str) -> Option<&'a Json> {
    settings
        .get("projectSettingsOverrides")?
        .get(project_id)?
        .get("defaultProjectScripts")
}

fn defaults(settings: &Json) -> Vec<Json> {
    settings
        .get("defaultProjectScripts")
        .and_then(Json::as_array)
        .cloned()
        .unwrap_or_default()
}

fn folded(settings: &Json) -> bool {
    settings
        .get("projectSettingsFolded")
        .and_then(Json::as_bool)
        .unwrap_or(false)
}

/// The scripts of `project_id`; `own` are the ones its row carries.
pub fn resolve(settings: &Json, project_id: &str, own: &[Json]) -> Vec<Json> {
    if let Some(list) = override_of(settings, project_id).and_then(Json::as_array) {
        return list.clone();
    }
    if folded(settings) || own.is_empty() {
        return defaults(settings);
    }
    own.to_vec()
}

/// Whether the project has no list of its own.
pub fn inherits(settings: &Json, project_id: &str, own: &[Json]) -> bool {
    if override_of(settings, project_id).is_some_and(Json::is_array) {
        return false;
    }
    folded(settings) || own.is_empty()
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn settings() -> Json {
        json!({
            "defaultProjectScripts": [{"name": "default"}],
            "projectSettingsOverrides": {
                "p1": {"defaultProjectScripts": [{"name": "mine"}]},
                "p2": {"defaultProjectScripts": null},
                "p3": {},
            },
        })
    }

    fn names(scripts: &[Json]) -> Vec<&str> {
        scripts.iter().filter_map(|s| s["name"].as_str()).collect()
    }

    #[test]
    fn a_projects_override_wins() {
        let own = [json!({"name": "row"})];
        assert_eq!(names(&resolve(&settings(), "p1", &own)), ["mine"]);
        assert!(!inherits(&settings(), "p1", &own));
        // Even an empty list is the project's own.
        let empty = json!({"projectSettingsOverrides": {"p": {"defaultProjectScripts": []}}});
        assert!(resolve(&empty, "p", &own).is_empty());
    }

    #[test]
    fn without_an_override_the_row_then_the_environment() {
        let own = [json!({"name": "row"})];
        // A null or missing override is none.
        for project in ["p2", "p3", "p4"] {
            assert_eq!(names(&resolve(&settings(), project, &own)), ["row"]);
            assert_eq!(names(&resolve(&settings(), project, &[])), ["default"]);
            assert!(!inherits(&settings(), project, &own));
            assert!(inherits(&settings(), project, &[]));
        }
    }

    #[test]
    fn folded_settings_leave_the_row_out() {
        let mut folded = settings();
        folded["projectSettingsFolded"] = json!(true);
        let own = [json!({"name": "row"})];
        assert_eq!(names(&resolve(&folded, "p4", &own)), ["default"]);
        assert!(inherits(&folded, "p4", &own));
        assert_eq!(names(&resolve(&folded, "p1", &own)), ["mine"]);
    }
}
