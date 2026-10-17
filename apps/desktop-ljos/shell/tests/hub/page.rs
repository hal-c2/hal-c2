//! What the settings pages' tests share: a hub with its MC ready and the
//! environment's config loaded, the section opened, and the calls read back.

use std::cell::RefCell;

use hal_c2_shell::json::Json;
use hal_c2_shell::mc::McError;
use serde_json::json;

use crate::Hub;

pub const READ: &str = "hal-c2.readSettings";
pub const WRITE: &str = "hal-c2.writeSettings";

/// A hub whose MC is ready and whose environment has said `config`
/// ({settings, providers, environment: {capabilities}}) at version 1.
pub fn hub_with(config: Json) -> Hub {
    let hub = Hub::new();
    hub.mc.set_ready(&hub.engine, true);
    send_config(&hub, config, 1);
    hub
}

thread_local! {
    /// The config the environment last said, and its version: a page that
    /// opens follows the environment's document afresh and hears it again.
    static CONFIG: RefCell<Option<(Json, i64)>> = const { RefCell::new(None) };
    /// The settings document the MC holds, and its version.
    static DOCUMENT: RefCell<(Json, i64)> = const { RefCell::new((Json::Null, 0)) };
}

/// A config frame, and the read it sets off, answered at `version`.
pub fn send_config(hub: &Hub, config: Json, version: i64) {
    let mut config = config;
    config["keybindingRules"] = json!([]);
    CONFIG.with(|c| *c.borrow_mut() = Some((config.clone(), version)));
    DOCUMENT.with(|d| *d.borrow_mut() = (config["settings"].clone(), version));
    let settings = config.get("settings").cloned().unwrap_or_else(|| json!({}));
    hub.mc.frame(
        &hub.engine,
        "config",
        // With a store the shapes name the MC, not the environment.
        "",
        json!({"t": "config", "config": config}),
    );
    if let Some(index) = hub.mc.pending_on("env-1", READ) {
        hub.mc.reply(
            &hub.engine,
            index,
            Ok(json!({"settings": settings, "version": version})),
        );
    }
}

/// Opens a section of Settings, as a link or the sidebar does.
pub fn open(hub: &Hub, section: &str) {
    hub.dispatch("settings.navigate", json!({"to": section}));
    if let Some((config, version)) = CONFIG.with(|c| c.borrow().clone()) {
        send_config(hub, config, version);
    }
}

/// The payload of the last call to `method` on `environment`.
pub fn last(hub: &Hub, environment: &str, method: &str) -> Json {
    hub.mc
        .calls
        .borrow()
        .iter()
        .rev()
        .find(|(e, m, _)| e == environment && m == method)
        .map(|(_, _, p)| p.clone())
        .unwrap_or_else(|| panic!("no {method} on {environment}"))
}

pub fn count(hub: &Hub, method: &str) -> usize {
    hub.mc.methods().iter().filter(|m| *m == method).count()
}

/// Answers the oldest unanswered call to `method` on `environment`.
pub fn answer(hub: &Hub, environment: &str, method: &str, result: Result<Json, McError>) {
    let index = hub
        .mc
        .pending_on(environment, method)
        .unwrap_or_else(|| panic!("no unanswered {method} on {environment}"));
    hub.mc.reply(&hub.engine, index, result);
}

/// A change reads the document first, then writes it at that version:
/// answers the read of the change just made with the document the MC holds.
pub fn settle(hub: &Hub) {
    while let Some(index) = hub.mc.pending_on("env-1", READ) {
        let (settings, version) = DOCUMENT.with(|d| d.borrow().clone());
        hub.mc.reply(
            &hub.engine,
            index,
            Ok(json!({"settings": settings, "version": version})),
        );
    }
}

/// The writes made so far, once the changes have read their documents.
pub fn writes(hub: &Hub) -> usize {
    settle(hub);
    count(hub, WRITE)
}

/// Saves what the last write asked, as the MC would: the document the page
/// reads next is that one.
pub fn accept_write(hub: &Hub, version: i64) {
    let settings = written(hub);
    answer(hub, "env-1", WRITE, Ok(json!({"version": version})));
    // The MC says the new document to everyone following it.
    if let Some((mut config, _)) = CONFIG.with(|c| c.borrow().clone()) {
        config["settings"] = settings;
        send_config(hub, config, version);
    }
}

/// The MC refuses the oldest write.
pub fn reject_write(hub: &Hub, message: &str) {
    settle(hub);
    answer(hub, "env-1", WRITE, Err(failure(message)));
}

/// The settings document the last write sent.
pub fn written(hub: &Hub) -> Json {
    settle(hub);
    last(hub, "env-1", WRITE)["settings"].clone()
}

/// The titles and descriptions of the toasts showing.
pub fn toasts(hub: &Hub) -> Vec<(String, String)> {
    hub.published("toasts")["items"]
        .as_array()
        .cloned()
        .unwrap_or_default()
        .iter()
        .map(|i| {
            (
                i["title"].as_str().unwrap_or_default().to_owned(),
                i["description"].as_str().unwrap_or_default().to_owned(),
            )
        })
        .collect()
}

pub fn failure(message: &str) -> McError {
    McError {
        message: message.into(),
        detail: Json::Null,
    }
}
