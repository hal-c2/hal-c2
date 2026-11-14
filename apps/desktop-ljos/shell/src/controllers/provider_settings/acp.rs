//! An ACP Registry agent's own sessions, model providers and sign-out on its
//! Providers card: the agent is asked from one of the shown environment's
//! projects (HalC2.Acp.Sessions), one request at a time.
//!
//! Actions: `providerSettings.acpProject {instanceId, projectId}`,
//! `.acpSessions {instanceId, more}` (lists them again, or the next page),
//! `.acpImport {instanceId, sessionId}`, `.acpDelete {instanceId, sessionId}`
//! (asks first), `.acpProviders {instanceId}`, `.acpSetProvider {instanceId,
//! providerId, apiType, baseUrl, headers}` (headers: JSON text, empty for
//! none), `.acpDisableProvider {instanceId, providerId}` (asks first),
//! `.acpLogout {instanceId}`.
//!
//! Each registry entry's `acp`: null when the agent offers none of it, else
//! {canList, canImport, canDelete, canLogout, canConfigure, projects [{id,
//! title}], projectId, sessions: null | [{sessionId, title, updatedAt, cwd,
//! imported}], more, providers: null | [{providerId, supported, required,
//! configured, apiType, baseUrl}], busy ("" or what runs: sessions, import,
//! delete, providers, provider, logout)}.

use ljos::prelude::Engine;
use serde_json::{Map, json};

use super::{
    Acp, ProviderSettings, REGISTRY, array_at, at, bool_at, confirm, empty, input_bool,
    input_string, str_at, toast,
};
use crate::json::Json;
use crate::store;

/// What a finished ACP call does with its answer.
type AcpDone = Box<dyn FnOnce(&mut ProviderSettings, &Engine, Json)>;

/// Why `text` is not a JSON object of strings, or the headers ({} for none).
fn headers(text: &str) -> Result<Map<String, Json>, &'static str> {
    if text.trim().is_empty() {
        return Ok(Map::new());
    }
    let Ok(document) = serde_json::from_str::<Json>(text) else {
        return Err("Headers must be valid JSON.");
    };
    match document {
        Json::Object(headers) if headers.values().all(Json::is_string) => Ok(headers),
        _ => Err("Headers must be a JSON object with string values."),
    }
}

/// What a published `busy` says a call to `method` is doing.
fn busy(method: &str) -> &'static str {
    match method {
        "server.listAcpRegistrySessions" => "sessions",
        "server.importAcpRegistrySession" => "import",
        "server.deleteAcpRegistrySession" => "delete",
        "server.listAcpRegistryProviders" => "providers",
        "server.logoutAcpRegistry" => "logout",
        _ => "provider",
    }
}

/// The session with this id among those last listed, or null.
fn session(acp: Option<&Acp>, session_id: &str) -> Json {
    acp.and_then(|a| a.sessions.as_ref())
        .into_iter()
        .flatten()
        .rfind(|s| str_at(s, "sessionId") == session_id)
        .cloned()
        .unwrap_or(Json::Null)
}

impl ProviderSettings {
    /// The project the agent is asked from: the chosen one while the shown
    /// environment has it, else its first.
    fn acp_project(&self, engine: &Engine, instance_id: &str) -> String {
        let chosen = self
            .acp
            .get(instance_id)
            .map(|a| a.project_id.clone())
            .unwrap_or_default();
        store::with(engine, |s| {
            let rows = s.project_rows(&self.followed);
            if rows.iter().any(|row| str_at_row(row, "id") == chosen) {
                return chosen;
            }
            rows.first()
                .map(|row| str_at_row(row, "id").to_owned())
                .unwrap_or_default()
        })
    }

    fn acp_call(
        &mut self,
        engine: &Engine,
        instance_id: &str,
        method: &str,
        payload: Json,
        failure: &str,
        done: AcpDone,
    ) {
        let acp = self.acp.entry(instance_id.to_owned()).or_default();
        if !acp.busy.is_empty() || self.followed.is_empty() {
            return;
        }
        let mut payload = payload.as_object().cloned().unwrap_or_default();
        payload.insert("instanceId".into(), json!(instance_id));
        acp.busy = busy(method).to_owned();
        self.publish(engine);
        let following = self.following;
        let me = self.me.clone();
        let id = instance_id.to_owned();
        let failure = failure.to_owned();
        self.mc.call(
            &self.followed,
            method,
            Json::Object(payload),
            Box::new(move |engine, result| {
                me.run(engine, move |c, engine| {
                    // The answer may come after the user moved on, and back.
                    if c.following != following {
                        return;
                    }
                    c.acp.entry(id).or_default().busy.clear();
                    match result {
                        Err(error) => toast(engine, "error", &failure, &error.message),
                        Ok(result) => {
                            let result = if result.is_object() {
                                result
                            } else {
                                json!({})
                            };
                            done(c, engine, result);
                        }
                    }
                    c.publish(engine);
                });
            }),
        );
    }

    pub(super) fn handle_acp(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !action.starts_with("providerSettings.acp") {
            return false;
        }
        let instance_id = str_at(payload, "instanceId").to_owned();
        if self.driver_of(&instance_id) != REGISTRY {
            return true;
        }
        let project_id = self.acp_project(engine, &instance_id);
        if action == "providerSettings.acpProject" {
            let acp = self.acp.entry(instance_id).or_default();
            if !acp.busy.is_empty() {
                return true;
            }
            *acp = Acp {
                project_id: input_string(payload, "projectId"),
                ..Acp::default()
            };
        } else if project_id.is_empty() && action != "providerSettings.acpLogout" {
            return true;
        } else {
            match action {
                "providerSettings.acpSessions" => {
                    self.list_acp_sessions(engine, &instance_id, &project_id, payload);
                }
                "providerSettings.acpImport" => {
                    self.import_acp_session(engine, &instance_id, &project_id, payload);
                }
                "providerSettings.acpDelete" => {
                    self.delete_acp_session(engine, &instance_id, &project_id, payload);
                }
                "providerSettings.acpProviders" => {
                    self.list_acp_providers(engine, &instance_id, &project_id);
                }
                "providerSettings.acpSetProvider" => {
                    self.set_acp_provider(engine, &instance_id, &project_id, payload);
                }
                "providerSettings.acpDisableProvider" => {
                    let provider_id = input_string(payload, "providerId");
                    let environment = self.followed.clone();
                    let id = instance_id.clone();
                    let project = project_id.clone();
                    let provider = provider_id.clone();
                    confirm(
                        engine,
                        &self.me,
                        "Disable ACP provider?",
                        &format!("Disable ACP provider \"{provider_id}\"?"),
                        "Disable",
                        move |c, engine| {
                            if c.followed != environment {
                                return;
                            }
                            let relist = (id.clone(), project.clone());
                            c.acp_call(
                                engine,
                                &id,
                                "server.disableAcpRegistryProvider",
                                json!({"projectId": project, "providerId": provider}),
                                "Could not disable ACP provider",
                                Box::new(move |c, engine, _| {
                                    toast(engine, "success", "ACP provider disabled", "");
                                    c.relist_acp_providers(engine, relist);
                                }),
                            );
                        },
                    );
                }
                "providerSettings.acpLogout" => {
                    let id = instance_id.clone();
                    self.acp_call(
                        engine,
                        &instance_id,
                        "server.logoutAcpRegistry",
                        json!({}),
                        "Could not log out of ACP agent",
                        Box::new(move |c, engine, _| {
                            let acp = c.acp.entry(id).or_default();
                            acp.sessions = None;
                            acp.next_cursor.clear();
                            toast(engine, "success", "Logged out of ACP agent", "");
                        }),
                    );
                }
                _ => {}
            }
        }
        self.publish(engine);
        true
    }

    fn list_acp_sessions(
        &mut self,
        engine: &Engine,
        instance_id: &str,
        project_id: &str,
        payload: &Json,
    ) {
        let cursor = self
            .acp
            .get(instance_id)
            .map(|a| a.next_cursor.clone())
            .unwrap_or_default();
        let more = input_bool(payload, "more") && !cursor.is_empty();
        let mut request = json!({"projectId": project_id});
        if more {
            request["cursor"] = json!(cursor);
        }
        let id = instance_id.to_owned();
        let project = project_id.to_owned();
        self.acp_call(
            engine,
            instance_id,
            "server.listAcpRegistrySessions",
            request,
            "Could not list ACP sessions",
            Box::new(move |c, _, result| {
                let acp = c.acp.entry(id).or_default();
                acp.project_id = project;
                let mut sessions = if more {
                    acp.sessions.clone().unwrap_or_default()
                } else {
                    Vec::new()
                };
                sessions.extend(array_at(&result, "sessions").iter().cloned());
                acp.sessions = Some(sessions);
                acp.next_cursor = str_at(&result, "nextCursor").to_owned();
            }),
        );
    }

    fn import_acp_session(
        &mut self,
        engine: &Engine,
        instance_id: &str,
        project_id: &str,
        payload: &Json,
    ) {
        let session_id = input_string(payload, "sessionId");
        let session = session(self.acp.get(instance_id), &session_id);
        if empty(&session) {
            return;
        }
        let mut request = json!({"projectId": project_id, "sessionId": session_id});
        for key in ["title", "updatedAt"] {
            if at(&session, key).is_string() {
                request[key] = at(&session, key).clone();
            }
        }
        let id = instance_id.to_owned();
        self.acp_call(
            engine,
            instance_id,
            "server.importAcpRegistrySession",
            request,
            "Could not import ACP session",
            Box::new(move |c, engine, result| {
                let acp = c.acp.entry(id).or_default();
                let mut sessions = acp.sessions.clone().unwrap_or_default();
                for row in &mut sessions {
                    if str_at(row, "sessionId") != session_id {
                        continue;
                    }
                    let mut object = row.as_object().cloned().unwrap_or_default();
                    match result.get("threadId").filter(|t| !t.is_null()) {
                        Some(thread) => object.insert("importedThreadId".into(), thread.clone()),
                        None => object.remove("importedThreadId"),
                    };
                    *row = Json::Object(object);
                }
                acp.sessions = Some(sessions);
                let title = if bool_at(&result, "imported") {
                    "ACP session imported"
                } else {
                    "ACP session already imported"
                };
                toast(engine, "success", title, "");
            }),
        );
    }

    fn delete_acp_session(
        &mut self,
        engine: &Engine,
        instance_id: &str,
        project_id: &str,
        payload: &Json,
    ) {
        let session_id = input_string(payload, "sessionId");
        let session = session(self.acp.get(instance_id), &session_id);
        if empty(&session) {
            return;
        }
        // An imported session goes with its thread first (the MC refuses it too).
        if at(&session, "importedThreadId").is_string() {
            toast(
                engine,
                "error",
                "Could not delete ACP session",
                "Delete the imported HAL-C2 thread before deleting its native ACP session.",
            );
            return;
        }
        let title = match at(&session, "title") {
            Json::String(title) => title.clone(),
            _ => session_id.clone(),
        };
        let environment = self.followed.clone();
        let id = instance_id.to_owned();
        let project = project_id.to_owned();
        confirm(
            engine,
            &self.me,
            "Delete native session?",
            &format!("Permanently delete native ACP session \"{title}\"?"),
            "Delete",
            move |c, engine| {
                if c.followed != environment {
                    return;
                }
                let kept_id = id.clone();
                let session_id = session_id.clone();
                c.acp_call(
                    engine,
                    &id,
                    "server.deleteAcpRegistrySession",
                    json!({"projectId": project, "sessionId": session_id}),
                    "Could not delete ACP session",
                    Box::new(move |c, engine, _| {
                        let acp = c.acp.entry(kept_id).or_default();
                        let mut kept = acp.sessions.clone().unwrap_or_default();
                        kept.retain(|s| str_at(s, "sessionId") != session_id);
                        acp.sessions = Some(kept);
                        toast(engine, "success", "ACP session deleted", "");
                    }),
                );
            },
        );
    }

    fn set_acp_provider(
        &mut self,
        engine: &Engine,
        instance_id: &str,
        project_id: &str,
        payload: &Json,
    ) {
        let api_type = input_string(payload, "apiType").trim().to_owned();
        let base_url = input_string(payload, "baseUrl").trim().to_owned();
        if api_type.is_empty() || base_url.is_empty() {
            return;
        }
        let headers = match headers(&input_string(payload, "headers")) {
            Ok(headers) => headers,
            Err(problem) => {
                toast(engine, "error", "Invalid provider headers", problem);
                return;
            }
        };
        let mut request = json!({
            "projectId": project_id,
            "providerId": input_string(payload, "providerId"),
            "apiType": api_type,
            "baseUrl": base_url,
        });
        if !headers.is_empty() {
            request["headers"] = Json::Object(headers);
        }
        let relist = (instance_id.to_owned(), project_id.to_owned());
        self.acp_call(
            engine,
            instance_id,
            "server.setAcpRegistryProvider",
            request,
            "Could not configure ACP provider",
            Box::new(move |c, engine, _| {
                toast(engine, "success", "ACP provider configured", "");
                c.relist_acp_providers(engine, relist);
            }),
        );
    }

    /// Lists the providers again once the call that changed them is done.
    fn relist_acp_providers(&self, engine: &Engine, (instance_id, project_id): (String, String)) {
        let me = self.me.clone();
        self.bridge.defer(engine, move |engine| {
            me.run(engine, |c, engine| {
                c.list_acp_providers(engine, &instance_id, &project_id);
            });
        });
    }

    fn list_acp_providers(&mut self, engine: &Engine, instance_id: &str, project_id: &str) {
        let id = instance_id.to_owned();
        self.acp_call(
            engine,
            instance_id,
            "server.listAcpRegistryProviders",
            json!({"projectId": project_id}),
            "Could not list ACP providers",
            Box::new(move |c, _, result| {
                c.acp.entry(id).or_default().providers =
                    Some(array_at(&result, "providers").to_vec());
            }),
        );
    }

    /// A registry entry's `acp`.
    pub(super) fn acp_entry(&self, engine: &Engine, provider: &Json) -> Json {
        let instance_id = str_at(provider, "instanceId");
        let sessions = at(provider, "nativeSessions");
        let can_list = bool_at(sessions, "canList");
        let can_logout = bool_at(at(provider, "auth"), "canLogout")
            && !bool_at(at(provider, "setup"), "canAuthenticate");
        let can_configure = bool_at(provider, "configurableProviders");
        if str_at(provider, "driver") != REGISTRY || (!can_list && !can_logout && !can_configure) {
            return Json::Null;
        }
        let state = self.acp.get(instance_id).cloned().unwrap_or_default();
        let projects: Vec<Json> = store::with(engine, |s| {
            s.project_rows(&self.followed)
                .iter()
                .map(|row| json!({"id": str_at_row(row, "id"), "title": str_at_row(row, "title")}))
                .collect()
        });
        let session_rows = match &state.sessions {
            None => Json::Null,
            Some(sessions) => sessions
                .iter()
                .map(|session| {
                    let id = str_at(session, "sessionId");
                    let title = match at(session, "title") {
                        Json::String(title) => title.as_str(),
                        _ => id,
                    };
                    json!({
                        "sessionId": id,
                        "title": title,
                        "updatedAt": str_at(session, "updatedAt"),
                        "cwd": str_at(session, "cwd"),
                        "imported": at(session, "importedThreadId").is_string(),
                    })
                })
                .collect(),
        };
        let provider_rows = match &state.providers {
            None => Json::Null,
            Some(providers) => providers
                .iter()
                .map(|entry| {
                    let current = at(entry, "current");
                    let supported = array_at(entry, "supported");
                    let configured = !empty(current);
                    let api_type = if configured {
                        str_at(current, "apiType").to_owned()
                    } else {
                        supported.first().map(variant_text).unwrap_or_default()
                    };
                    json!({
                        "providerId": str_at(entry, "providerId"),
                        "supported": supported,
                        "required": bool_at(entry, "required"),
                        "configured": configured,
                        "apiType": api_type,
                        "baseUrl": str_at(current, "baseUrl"),
                    })
                })
                .collect(),
        };
        json!({
            "canList": can_list,
            "canImport": bool_at(sessions, "canLoad") || bool_at(sessions, "canResume"),
            "canDelete": bool_at(sessions, "canDelete"),
            "canLogout": can_logout,
            "canConfigure": can_configure,
            "projects": projects,
            "projectId": self.acp_project(engine, instance_id),
            "sessions": session_rows,
            "more": !state.next_cursor.is_empty(),
            "providers": provider_rows,
            "busy": state.busy,
        })
    }
}

/// A store row's string field.
fn str_at_row<'a>(row: &'a store::Row, key: &str) -> &'a str {
    row.get(key).and_then(Json::as_str).unwrap_or_default()
}

/// A value as QVariant::toString reads it.
fn variant_text(value: &Json) -> String {
    super::input_string(&json!({"v": value}), "v")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn headers_are_an_object_of_strings() {
        assert_eq!(headers("  "), Ok(Map::new()));
        assert_eq!(headers("{"), Err("Headers must be valid JSON."));
        assert_eq!(
            headers("[1]"),
            Err("Headers must be a JSON object with string values.")
        );
        assert_eq!(
            headers(r#"{"a": 1}"#),
            Err("Headers must be a JSON object with string values.")
        );
        assert_eq!(headers(r#"{"a": "b"}"#).unwrap()["a"], "b");
    }
}
