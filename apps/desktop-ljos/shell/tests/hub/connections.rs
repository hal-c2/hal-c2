//! `connections`: who may reach this MC, live while the page is open
//! (ConnectionsController.cpp, features/connections/).

use std::cell::RefCell;
use std::rc::Rc;

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controllers::settings_scope::{Environment, SettingsScope};
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::McError;
use serde_json::json;

use crate::Hub;

fn page(hub: &Hub) -> Json {
    hub.published("connections")
}

/// A hub with the Connections page open and its access subscription
/// followed; `env-1` is this MC and `env-2` another machine online.
fn open() -> Hub {
    let hub = Hub::new();
    hub.mc.set_ready(&hub.engine, true);
    SettingsScope::of(&hub.engine).set_sources(
        &hub.engine,
        Rc::new(|_| {
            vec![
                Environment {
                    id: "env-2".into(),
                    label: "Build box".into(),
                    online: true,
                },
                Environment {
                    id: "env-1".into(),
                    label: "Laptop".into(),
                    online: true,
                },
                Environment {
                    id: "env-3".into(),
                    label: "Asleep".into(),
                    online: false,
                },
            ]
        }),
        Rc::new(|_| Vec::new()),
    );
    hub.dispatch("connections.open", json!({}));
    hub
}

fn access(hub: &Hub, event: Json) {
    hub.mc.frame(
        &hub.engine,
        "authAccess",
        "",
        json!({"t": "authAccess", "event": event}),
    );
}

fn snapshot(hub: &Hub) {
    access(
        hub,
        json!({"type": "snapshot", "payload": {
            "pairingLinks": [{"id": "l1", "label": "Phone"}],
            "clientSessions": [{"sessionId": "s1", "client": {"label": "Pixel"}}, {"sessionId": "s2", "client": {"deviceType": "desktop"}}],
        }}),
    );
}

fn clipboard(hub: &Hub) -> Rc<RefCell<Vec<String>>> {
    let copied = Rc::new(RefCell::new(Vec::new()));
    let sink = copied.clone();
    Bridge::of(&hub.engine).set_clipboard_writer(&hub.engine, move |text| {
        sink.borrow_mut().push(text.to_owned())
    });
    copied
}

#[test]
fn the_access_list_is_followed_while_the_page_is_open_and_forgotten_after() {
    let hub = Hub::new();
    hub.dispatch("settings.open", json!({}));
    let followed = |hub: &Hub| {
        hub.mc
            .subscriptions()
            .into_iter()
            .filter(|(_, s)| s["type"] == "authAccess")
            .count()
    };
    assert_eq!(followed(&hub), 0);
    assert_eq!(page(&hub)["access"], Json::Null);

    hub.dispatch("connections.open", json!({}));
    assert_eq!(followed(&hub), 1);
    snapshot(&hub);
    assert_eq!(
        page(&hub)["access"]["pairingLinks"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(page(&hub)["access"]["clients"].as_array().unwrap().len(), 2);

    // Live changes: replaced by id, added, removed.
    access(
        &hub,
        json!({"type": "pairingLinkUpserted", "payload": {"id": "l1", "label": "Tablet"}}),
    );
    access(
        &hub,
        json!({"type": "pairingLinkUpserted", "payload": {"id": "l2", "label": "Second"}}),
    );
    access(
        &hub,
        json!({"type": "clientRemoved", "payload": {"sessionId": "s1"}}),
    );
    access(
        &hub,
        json!({"type": "pairingLinkRemoved", "payload": {"id": "l2"}}),
    );
    let state = page(&hub);
    assert_eq!(
        state["access"]["pairingLinks"],
        json!([{"id": "l1", "label": "Tablet"}])
    );
    assert_eq!(state["access"]["clients"].as_array().unwrap().len(), 1);

    hub.dispatch("connections.close", json!({}));
    assert_eq!(followed(&hub), 0);
    assert_eq!(page(&hub)["access"], Json::Null);
}

#[test]
fn a_session_without_access_is_told_to_pair_with_an_administrator_link() {
    let hub = open();
    hub.mc.frame(
        &hub.engine,
        "authAccess",
        "",
        json!({"t": "error", "reason": "access:read is required"}),
    );
    let state = page(&hub);
    assert_eq!(state["accessNeedsAdmin"], true);
    assert!(
        state["accessError"]
            .as_str()
            .unwrap()
            .starts_with("Managing this machine's access needs an administrator session.")
    );
    assert_eq!(state["access"], Json::Null);
    // Refreshing follows it again.
    hub.dispatch("connections.refresh", json!({}));
    assert_eq!(page(&hub)["accessError"], Json::Null);
    assert_eq!(
        hub.mc
            .subscriptions()
            .iter()
            .filter(|(_, s)| s["type"] == "authAccess")
            .count(),
        1
    );
}

#[test]
fn the_machines_a_link_can_be_for_are_the_online_ones_this_one_first() {
    let hub = open();
    assert_eq!(
        page(&hub)["machines"],
        json!([{"id": "env-1", "label": "Laptop"}, {"id": "env-2", "label": "Build box"}])
    );
}

#[test]
fn a_link_needs_a_permission_and_is_created_on_the_machine_chosen() {
    let hub = open();
    hub.dispatch(
        "connections.pairingLink.create",
        json!({"label": "x", "scopes": []}),
    );
    assert_eq!(
        page(&hub)["notice"],
        json!({"kind": "error", "text": "Select at least one permission."})
    );
    assert!(hub.mc.pending("hal-c2.createPairingLink").is_none());

    hub.dispatch(
        "connections.pairingLink.create",
        json!({"label": "  Phone ", "scopes": ["read"], "environmentId": "env-2"}),
    );
    assert_eq!(page(&hub)["busy"], true);
    let index = hub
        .mc
        .pending_on("env-2", "hal-c2.createPairingLink")
        .unwrap();
    assert_eq!(
        hub.mc.calls.borrow()[index].2,
        json!({"scopes": ["read"], "label": "Phone"})
    );
    hub.mc.reply(&hub.engine, index, Ok(json!({
        "id": "l9", "label": "Phone", "credential": "CODE", "address": "http://build:4800", "expiresAt": "2026-03-10T13:00:00Z",
    })));
    let state = page(&hub);
    assert_eq!(state["busy"], false);
    let created = &state["created"];
    assert_eq!(created["url"], "http://build:4800/pair#token=CODE");
    assert_eq!(created["machine"], "Build box");
    assert_eq!(created["elsewhere"], true);
    assert_eq!(created["localOnly"], false);
    assert!(created["qr"]["modules"].as_u64().unwrap() > 0);
    assert_eq!(state["notice"]["kind"], "success");
}

#[test]
fn a_link_from_an_mc_that_cannot_say_where_it_is_reached_is_revoked_not_shown() {
    let hub = open();
    hub.dispatch(
        "connections.pairingLink.create",
        json!({"scopes": ["read"]}),
    );
    hub.mc.answer_on(
        &hub.engine,
        "env-1",
        "hal-c2.createPairingLink",
        Ok(json!({"id": "l9", "credential": "CODE"})),
    );
    let state = page(&hub);
    assert_eq!(state["created"], Json::Null);
    assert_eq!(state["notice"]["kind"], "error");
    assert!(
        state["notice"]["text"]
            .as_str()
            .unwrap()
            .contains("Laptop did not say where it can be reached")
    );
    let revoke = hub
        .mc
        .pending_on("env-1", "hal-c2.revokePairingLink")
        .unwrap();
    assert_eq!(hub.mc.calls.borrow()[revoke].2, json!({"id": "l9"}));
}

#[test]
fn a_link_that_arrives_after_the_page_closed_or_another_was_asked_is_revoked() {
    let hub = open();
    let reply = json!({"id": "late", "credential": "C", "address": "http://laptop:4800"});
    hub.dispatch(
        "connections.pairingLink.create",
        json!({"scopes": ["read"]}),
    );
    hub.dispatch("connections.close", json!({}));
    hub.mc
        .answer(&hub.engine, "hal-c2.createPairingLink", Ok(reply.clone()));
    assert_eq!(page(&hub)["created"], Json::Null);
    assert!(hub.mc.pending("hal-c2.revokePairingLink").is_some());

    let hub = open();
    hub.dispatch(
        "connections.pairingLink.create",
        json!({"scopes": ["read"]}),
    );
    hub.dispatch(
        "connections.pairingLink.create",
        json!({"scopes": ["write"]}),
    );
    let first = hub.mc.pending("hal-c2.createPairingLink").unwrap();
    hub.mc.reply(&hub.engine, first, Ok(reply));
    assert_eq!(page(&hub)["created"], Json::Null);
    assert!(hub.mc.pending("hal-c2.revokePairingLink").is_some());
    let second = hub.mc.pending("hal-c2.createPairingLink").unwrap();
    hub.mc.reply(
        &hub.engine,
        second,
        Ok(json!({"id": "l2", "credential": "D", "address": "http://laptop:4800"})),
    );
    assert_eq!(page(&hub)["created"]["id"], "l2");
}

#[test]
fn copying_puts_the_link_or_the_code_on_the_clipboard_and_revoking_clears_it() {
    let hub = open();
    let copied = clipboard(&hub);
    hub.dispatch(
        "connections.pairingLink.create",
        json!({"scopes": ["read"]}),
    );
    hub.mc.answer(
        &hub.engine,
        "hal-c2.createPairingLink",
        Ok(json!({"id": "l9", "credential": "CODE", "address": "http://laptop:4800"})),
    );
    hub.dispatch("connections.pairingLink.copy", json!({"what": "url"}));
    hub.dispatch("connections.pairingLink.copy", json!({"what": "code"}));
    assert_eq!(
        *copied.borrow(),
        ["http://laptop:4800/pair#token=CODE", "CODE"]
    );
    assert_eq!(page(&hub)["notice"]["text"], "Pairing code copied.");

    hub.dispatch("connections.pairingLink.revoke", json!({"id": "l9"}));
    hub.mc.answer_on(
        &hub.engine,
        "env-1",
        "hal-c2.revokePairingLink",
        Ok(json!({})),
    );
    assert_eq!(page(&hub)["created"], Json::Null);
    assert_eq!(page(&hub)["notice"]["text"], "Pairing link revoked.");
}

#[test]
fn a_link_made_elsewhere_is_revoked_there() {
    let hub = open();
    hub.dispatch(
        "connections.pairingLink.create",
        json!({"scopes": ["read"], "environmentId": "env-2"}),
    );
    hub.mc.answer_on(
        &hub.engine,
        "env-2",
        "hal-c2.createPairingLink",
        Ok(json!({"id": "l9", "credential": "C", "address": "http://build:4800"})),
    );
    hub.dispatch("connections.pairingLink.revoke", json!({"id": "l9"}));
    assert!(
        hub.mc
            .pending_on("env-2", "hal-c2.revokePairingLink")
            .is_some()
    );
}

#[test]
fn revoking_a_client_names_it_and_the_others_count() {
    let hub = open();
    snapshot(&hub);
    hub.dispatch("connections.client.revoke", json!({"sessionId": "s1"}));
    hub.mc
        .answer(&hub.engine, "hal-c2.revokeClient", Ok(json!({})));
    assert_eq!(page(&hub)["notice"]["text"], "Pixel was signed out.");
    hub.dispatch("connections.client.revoke", json!({"sessionId": "s2"}));
    hub.mc
        .answer(&hub.engine, "hal-c2.revokeClient", Ok(json!({})));
    assert_eq!(page(&hub)["notice"]["text"], "desktop was signed out.");
    hub.dispatch("connections.client.revoke", json!({"sessionId": "gone"}));
    hub.mc
        .answer(&hub.engine, "hal-c2.revokeClient", Ok(json!({})));
    assert_eq!(page(&hub)["notice"]["text"], "The client was signed out.");

    hub.dispatch("connections.clients.revokeOthers", json!({}));
    hub.mc.answer(
        &hub.engine,
        "hal-c2.revokeOtherClients",
        Ok(json!({"revokedCount": 1})),
    );
    assert_eq!(page(&hub)["notice"]["text"], "1 client was revoked.");
    hub.dispatch("connections.clients.revokeOthers", json!({}));
    hub.mc.answer(
        &hub.engine,
        "hal-c2.revokeOtherClients",
        Ok(json!({"revokedCount": 3})),
    );
    assert_eq!(page(&hub)["notice"]["text"], "3 clients were revoked.");
}

#[test]
fn a_refusal_is_said_in_the_notice() {
    let hub = open();
    hub.dispatch("connections.clients.revokeOthers", json!({}));
    hub.mc.answer(
        &hub.engine,
        "hal-c2.revokeOtherClients",
        Err(McError::new("access:write is required")),
    );
    let state = page(&hub);
    assert_eq!(state["busy"], false);
    assert_eq!(state["notice"]["kind"], "error");
    assert!(state["notice"]["text"].as_str().unwrap().starts_with("Could not revoke the other clients: Managing this machine's access needs an administrator session."));
}
