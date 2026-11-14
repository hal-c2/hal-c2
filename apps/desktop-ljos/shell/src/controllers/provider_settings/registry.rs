//! The add-provider wizard's ACP Registry: the registry's compatible agents,
//! searched on the shown environment, and choosing one, which the environment
//! installs before the wizard names the instance after it. An agent can also
//! be entered by hand.
//!
//! Actions (while the wizard shows): `providerSettings.registrySearch
//! {query}` (the wizard searches with an empty query as it opens),
//! `.registryAdd {agentId}` (prepares the agent, then moves on to Identity),
//! `.registryManual {manual}` (the registry driver's own fields instead of a
//! search), `.registryAbout {agentId}` (its website, else its repository).
//!
//! `wizard.registry`: {query, searching, error, agents [{id, name,
//! description, iconUrl, website, added, preparing, progress ("Preparing" |
//! "Downloading")}] (null before the first answer), busy, manual, selected
//! (null | {id, name, version}), selectionError ("" until moving on was
//! tried)}.

use ljos::prelude::Engine;
use serde_json::{Map, json};

use super::{
    ProviderSettings, REGISTRY, at, authority, error_text, input_bool, input_string,
    insert_defined, scheme, str_at,
};
use crate::json::Json;
use crate::provider::drivers;

/// resolveOfficialAcpRegistryIconUrl: only the registry's own CDN.
fn official_icon(icon: &str) -> String {
    let authority = authority(icon);
    let official = scheme(icon) == "https"
        && !authority.contains('@')
        && !authority.contains(':')
        && authority == "cdn.agentclientprotocol.com";
    if official {
        icon.to_owned()
    } else {
        String::new()
    }
}

/// isConfiguredAcpRegistryAgent: an instance already runs the agent.
fn configured(settings: &Json, agent_id: &str) -> bool {
    at(settings, "providerInstances")
        .as_object()
        .into_iter()
        .flat_map(Map::values)
        .any(|instance| {
            str_at(instance, "driver") == REGISTRY
                && str_at(at(instance, "config"), "agentId") == agent_id
        })
}

/// An agent's website, else its repository.
fn website(agent: &Json) -> &str {
    match str_at(agent, "website") {
        "" => str_at(agent, "repository"),
        website => website,
    }
}

impl ProviderSettings {
    /// Why the wizard cannot move on from Provider: the registry driver
    /// without an agent chosen or entered by hand.
    pub(super) fn registry_selection_error(&self) -> String {
        match &self.wizard {
            Some(w) if w.driver == REGISTRY && w.selected.is_empty() && !w.manual => {
                "Select an ACP or configure one manually.".into()
            }
            _ => String::new(),
        }
    }

    pub(super) fn search_registry(&mut self, _engine: &Engine, query: String) {
        if self.followed.is_empty() {
            return;
        }
        let Some(wizard) = self.wizard.as_mut() else {
            return;
        };
        wizard.query = query.trim().to_owned();
        wizard.searching = true;
        wizard.registry_error.clear();
        wizard.generation += 1;
        let generation = wizard.generation;
        let wizard_id = wizard.id;
        let me = self.me.clone();
        self.mc.call(
            &self.followed,
            "server.searchAcpRegistry",
            json!({"query": wizard.query}),
            Box::new(move |engine, result| {
                me.run(engine, move |c, engine| {
                    // A later search, or a wizard since closed, owns the answer.
                    let Some(wizard) = c
                        .wizard
                        .as_mut()
                        .filter(|w| w.id == wizard_id && w.generation == generation)
                    else {
                        return;
                    };
                    wizard.searching = false;
                    match result {
                        Err(error) => {
                            wizard.registry_error =
                                error_text(&error, "The ACP Registry could not be searched.");
                        }
                        Ok(result) => {
                            wizard.agents = Some(
                                at(&result, "agents")
                                    .as_array()
                                    .cloned()
                                    .unwrap_or_default(),
                            );
                        }
                    }
                    c.publish(engine);
                });
            }),
        );
    }

    pub(super) fn handle_registry(
        &mut self,
        engine: &Engine,
        action: &str,
        payload: &Json,
    ) -> bool {
        if !action.starts_with("providerSettings.registry") {
            return false;
        }
        if action == "providerSettings.registryAbout"
            && let Some(wizard) = &self.wizard
        {
            // The agent's website, else its repository, in the user's browser.
            let agent_id = input_string(payload, "agentId");
            for agent in wizard.agents.iter().flatten() {
                if str_at(agent, "id") != agent_id {
                    continue;
                }
                let url = website(agent);
                if matches!(scheme(url).as_str(), "https" | "http") {
                    self.bridge.open_external(engine, url);
                }
            }
            return true;
        }
        if self
            .wizard
            .as_ref()
            .is_none_or(|w| w.saving || !w.preparing.is_empty())
        {
            return true;
        }
        match action {
            "providerSettings.registrySearch" => {
                self.search_registry(engine, input_string(payload, "query"));
            }
            "providerSettings.registryManual" => {
                if let Some(wizard) = self.wizard.as_mut() {
                    wizard.manual = input_bool(payload, "manual");
                    wizard.attempted = false;
                    if wizard.manual {
                        wizard.driver = REGISTRY.into();
                        wizard.selected.clear();
                        wizard.config.remove(REGISTRY);
                        let mut identity = Map::new();
                        identity.insert("label".into(), json!(""));
                        wizard.identity.insert(REGISTRY.into(), identity);
                    }
                }
            }
            "providerSettings.registryAdd" => self.add_registry_agent(payload),
            _ => {}
        }
        self.publish(engine);
        true
    }

    fn add_registry_agent(&mut self, payload: &Json) {
        let agent_id = input_string(payload, "agentId");
        let settings = self.shown_settings().unwrap_or_else(|| json!({}));
        if self.followed.is_empty() || configured(&settings, &agent_id) {
            return;
        }
        let Some(wizard) = self.wizard.as_mut() else {
            return;
        };
        let Some(agent) = wizard
            .agents
            .iter()
            .flatten()
            .rfind(|a| str_at(a, "id") == agent_id)
            .filter(|a| !super::empty(a))
            .cloned()
        else {
            return;
        };
        wizard.preparing = agent_id.clone();
        wizard.registry_error.clear();
        let wizard_id = wizard.id;
        let me = self.me.clone();
        self.mc.call(
            &self.followed,
            "server.prepareAcpRegistryAgent",
            json!({"agentId": agent_id}),
            Box::new(move |engine, result| {
                me.run(engine, move |c, engine| {
                    let taken = c.taken();
                    // A wizard closed (or reopened) since has moved on.
                    let Some(wizard) = c.wizard.as_mut().filter(|w| w.id == wizard_id) else {
                        return;
                    };
                    wizard.preparing.clear();
                    let prepared = match result {
                        Err(error) => {
                            wizard.registry_error =
                                error_text(&error, "The ACP could not be prepared.");
                            c.publish(engine);
                            return;
                        }
                        Ok(prepared) => prepared,
                    };
                    let id = match at(&prepared, "agentId") {
                        Json::String(id) => id.clone(),
                        _ => str_at(&agent, "id").to_owned(),
                    };
                    let name = str_at(&agent, "name").to_owned();
                    wizard.driver = REGISTRY.into();
                    wizard.manual = false;
                    wizard.attempted = false;
                    let mut selected = Map::new();
                    selected.insert("id".into(), json!(id));
                    selected.insert("name".into(), json!(name));
                    insert_defined(&mut selected, "version", at(&prepared, "version"));
                    wizard.selected = selected;
                    let mut identity = Map::new();
                    identity.insert(
                        "instanceId".into(),
                        json!(drivers::derive_id(REGISTRY, &name, &taken)),
                    );
                    identity.insert("label".into(), json!(name));
                    wizard.identity.insert(REGISTRY.into(), identity);
                    let mut config = Map::new();
                    config.insert("agentId".into(), json!(id));
                    config.insert("distribution".into(), json!("auto"));
                    let icon = official_icon(str_at(&agent, "icon"));
                    if !icon.is_empty() {
                        config.insert("registryIconUrl".into(), json!(icon));
                    }
                    wizard.config.insert(REGISTRY.into(), config);
                    wizard.step = 1;
                    c.publish(engine);
                });
            }),
        );
    }

    /// The wizard's registry search; the wizard is open.
    pub(super) fn registry_entry(&self) -> Json {
        let Some(wizard) = &self.wizard else {
            return Json::Null;
        };
        let settings = self.shown_settings().unwrap_or_else(|| json!({}));
        let agents = match &wizard.agents {
            None => Json::Null,
            Some(agents) => agents
                .iter()
                .map(|agent| {
                    let id = str_at(agent, "id");
                    json!({
                        "id": id,
                        "name": str_at(agent, "name"),
                        "description": str_at(agent, "description"),
                        "iconUrl": official_icon(str_at(agent, "icon")),
                        "website": website(agent),
                        "added": configured(&settings, id),
                        "preparing": wizard.preparing == id,
                        "progress": if str_at(agent, "distribution") == "binary" { "Downloading" } else { "Preparing" },
                    })
                })
                .collect(),
        };
        json!({
            "query": wizard.query,
            "searching": wizard.searching,
            "error": wizard.registry_error,
            "agents": agents,
            "busy": !wizard.preparing.is_empty(),
            "manual": wizard.manual,
            "selected": if wizard.selected.is_empty() { Json::Null } else { Json::Object(wizard.selected.clone()) },
            "selectionError": if wizard.attempted { self.registry_selection_error() } else { String::new() },
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_registry_cdn_gives_icons() {
        let icon = "https://cdn.agentclientprotocol.com/a.svg";
        assert_eq!(official_icon(icon), icon);
        assert!(!official_icon("https://CDN.agentclientprotocol.com/a.svg").is_empty());
        assert_eq!(
            official_icon("http://cdn.agentclientprotocol.com/a.svg"),
            ""
        );
        assert_eq!(
            official_icon("https://cdn.agentclientprotocol.com:443/a.svg"),
            ""
        );
        assert_eq!(
            official_icon("https://u@cdn.agentclientprotocol.com/a.svg"),
            ""
        );
        assert_eq!(official_icon("https://evil.example/a.svg"), "");
        assert_eq!(official_icon(""), "");
    }
}
