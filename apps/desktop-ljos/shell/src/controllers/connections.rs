//! `connections`, desktop-qt's ConnectionsController: the Connections
//! settings page, which the shell owns. Who may reach this MC (`HalC2.Auth`:
//! pairing links and paired clients, live through the `authAccess` shape
//! while the page is open). Other machines join on the Cluster page.
//!
//! Publishes `connections`:
//!   {access: {pairingLinks, clients} | null, accessError, accessNeedsAdmin,
//!    busy, notice: {kind, text} | null,
//!    machines: [{id, label}] (the cluster's machines that are online, a
//!    pairing link can be for any of them; the shell's own MC first),
//!    created: {id, label, url, code, expiresAt, environmentId, machine (its
//!    label), elsewhere (not the shell's own MC: its link is not in
//!    `access`), localOnly (only that machine can open the link), qr:
//!    {modules, path} | null (the link as a QR code, qr::path; none for a
//!    local-only link)} | null,
//!    revealed (false after a copy; desktop-qt sets it when the clipboard
//!    refuses, which this one never does)}
//!
//! `connections.pairingLink.create {label, scopes, environmentId,
//! tailscale}` asks the machine named (the shell's own MC when none is) for
//! the link, over Tailscale Serve when asked; the MC answers with the
//! address it is reached at. A link that arrives after the page closed, or
//! after another was asked for, is revoked on its machine instead of shown.
//! Also `.pairingLink.copy {what: url | code}`, `.pairingLink.revoke {id}`,
//! `connections.client.revoke {sessionId}`, `connections.clients.revokeOthers`
//! and `connections.refresh`.
//!
//! The page shows while the route is the settings section
//! "/settings/connections" (Navigation takes `connections.open` and
//! `.close`). Managing access needs an administrative session; the MC's
//! refusal becomes `accessError` or the notice.

use std::rc::Rc;

use ljos::prelude::Engine;
use serde_json::{Map, json};
use url::{Host, Url};

use crate::bridge::Bridge;
use crate::controller::{Controller, Init, Me};
use crate::controllers::navigation::{CONNECTIONS_SECTION, at_section};
use crate::controllers::settings_scope::SettingsScope;
use crate::json::Json;
use crate::mc::{Mc, SubId};
use crate::qr;

const KEY: &str = "connections";

/// The MC refuses access calls and the access list to a session without
/// access:read / access:write ("access:write is required").
const NEEDS_ADMIN: &str = "Managing this machine's access needs an administrator session. Pair this desktop with a link that grants Manage access.";

fn lacks_admin(error: &str) -> bool {
    error.starts_with("access:") && error.ends_with(" is required")
}

fn explain(error: &str) -> String {
    if lacks_admin(error) {
        NEEDS_ADMIN.into()
    } else {
        error.into()
    }
}

/// The link a client pairs with: the address its MC is reached at and the
/// code. A phone's camera opens it as a page of that MC (`GET /pair`), and
/// the app reads it scanned, pasted or handed over by that page.
fn pairing_url(address: &str, code: &str) -> String {
    format!("{address}/pair#token={code}")
}

/// All of 127.0.0.0/8 and ::1 are this machine, not only 127.0.0.1.
fn loopback(address: &Url) -> bool {
    match address.host() {
        Some(Host::Domain(name)) => name.eq_ignore_ascii_case("localhost"),
        Some(Host::Ipv4(ip)) => ip.is_loopback(),
        Some(Host::Ipv6(ip)) => ip.is_loopback(),
        None => false,
    }
}

/// `origin` without its path, query and fragment.
fn address_of(origin: &str) -> Option<Url> {
    let mut url = Url::parse(origin).ok()?;
    url.set_path("");
    url.set_query(None);
    url.set_fragment(None);
    Some(url)
}

fn text(address: &Url) -> String {
    address.as_str().trim_end_matches('/').to_owned()
}

type Done = Box<dyn FnOnce(&mut Connections, &Engine, &Json)>;

pub struct Connections {
    bridge: Bridge,
    me: Me<Connections>,
    mc: Rc<dyn Mc>,
    state: Map<String, Json>,
    /// The access list as the MC last described it, while the page is open.
    pairing_links: Vec<Json>,
    clients: Vec<Json>,
    access: Option<SubId>,
    /// The pairing link the page last asked for, counted; closing the page
    /// counts too, so the answer to any other request is discarded.
    link_request: u64,
    active: bool,
    open: bool,
}

impl Controller for Connections {
    fn new(init: Init<'_, Self>) -> Self {
        let state = match json!({
            "access": null,
            "accessError": null,
            "accessNeedsAdmin": false,
            "busy": false,
            "notice": null,
            "machines": [],
            "created": null,
        }) {
            Json::Object(map) => map,
            _ => Map::new(),
        };
        Connections {
            bridge: init.bridge,
            me: init.me,
            mc: init.mc,
            state,
            pairing_links: Vec::new(),
            clients: Vec::new(),
            access: None,
            link_request: 0,
            active: false,
            open: false,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        self.publish(engine);
        let me = self.me.clone();
        self.bridge.watch(engine, KEY_ROUTE, move |engine, route| {
            let open = at_section(route, CONNECTIONS_SECTION);
            me.run(engine, |c, engine| c.set_open(engine, open));
        });
        let route = self.bridge.published(engine, KEY_ROUTE);
        self.set_open(
            engine,
            route.is_some_and(|r| at_section(&r, CONNECTIONS_SECTION)),
        );
        // Machines that join, leave, sleep or wake change which ones a link
        // can be for.
        let me = self.me.clone();
        crate::store::on_changed(engine, move |engine| {
            me.run(engine, |c, engine| c.machines_changed(engine));
        });
        let me = self.me.clone();
        self.mc.on_ready_changed(Box::new(move |engine, _| {
            me.run(engine, |c, engine| c.machines_changed(engine));
        }));
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        // Opening and closing the page are the route's (Navigation).
        if !self.active
            || !action.starts_with("connections.")
            || matches!(action, "connections.open" | "connections.close")
        {
            return false;
        }
        let field = |key: &str| {
            payload
                .get(key)
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        match action {
            "connections.refresh" => self.watch_access(engine),
            "connections.pairingLink.create" => self.create_pairing_link(engine, payload),
            "connections.pairingLink.copy" => {
                let code = field("what") == "code";
                let created = self.state.get("created").cloned().unwrap_or_default();
                let text = created
                    .get(if code { "code" } else { "url" })
                    .and_then(Json::as_str)
                    .unwrap_or_default();
                if !text.is_empty() {
                    self.bridge.copy_to_clipboard(engine, text);
                    self.state.insert("revealed".into(), false.into());
                    self.set_notice(
                        engine,
                        "success",
                        if code {
                            "Pairing code copied."
                        } else {
                            "Pairing link copied."
                        },
                    );
                }
            }
            "connections.pairingLink.revoke" => {
                let id = field("id");
                if id.is_empty() {
                    return true;
                }
                // A link made on another machine is that machine's to revoke.
                let created = self.state.get("created").cloned().unwrap_or_default();
                let environment = if created.get("id").and_then(Json::as_str) == Some(&id) {
                    created
                        .get("environmentId")
                        .and_then(Json::as_str)
                        .unwrap_or_default()
                        .to_owned()
                } else {
                    self.mc.environment()
                };
                self.change(
                    engine,
                    &environment,
                    "hal-c2.revokePairingLink",
                    json!({"id": id}),
                    Box::new(move |c, engine, _| {
                        let shown = c.state.get("created").and_then(|c| c.get("id"));
                        if shown.and_then(Json::as_str) == Some(&id) {
                            c.state.insert("created".into(), Json::Null);
                        }
                        c.set_notice(engine, "success", "Pairing link revoked.");
                    }),
                    "Could not revoke the pairing link",
                );
            }
            "connections.client.revoke" => {
                let id = field("sessionId");
                if id.is_empty() {
                    return true;
                }
                let mut label = "The client".to_owned();
                for client in &self.clients {
                    if client.get("sessionId").and_then(Json::as_str) != Some(&id) {
                        continue;
                    }
                    let about = client.get("client").cloned().unwrap_or_default();
                    let said = |key: &str| about.get(key).and_then(Json::as_str).map(str::to_owned);
                    // Its label, else its device type, else what it was.
                    label = said("label")
                        .or_else(|| said("deviceType"))
                        .unwrap_or(label);
                }
                let environment = self.mc.environment();
                self.change(
                    engine,
                    &environment,
                    "hal-c2.revokeClient",
                    json!({"sessionId": id}),
                    Box::new(move |c, engine, _| {
                        c.set_notice(engine, "success", &format!("{label} was signed out."));
                    }),
                    "Could not revoke the client",
                );
            }
            "connections.clients.revokeOthers" => {
                let environment = self.mc.environment();
                self.change(
                    engine,
                    &environment,
                    "hal-c2.revokeOtherClients",
                    json!({}),
                    Box::new(|c, engine, result| {
                        let count = result
                            .get("revokedCount")
                            .and_then(Json::as_i64)
                            .unwrap_or(0);
                        let notice = if count == 1 {
                            "1 client was revoked.".to_owned()
                        } else {
                            format!("{count} clients were revoked.")
                        };
                        c.set_notice(engine, "success", &notice);
                    }),
                    "Could not revoke the other clients",
                );
            }
            _ => return false,
        }
        true
    }
}

const KEY_ROUTE: &str = "route";

impl Connections {
    /// Open, the page watches the access list; closed, it forgets it and the
    /// one pairing link it could still copy.
    fn set_open(&mut self, engine: &Engine, open: bool) {
        if open == self.open {
            return;
        }
        self.open = open;
        self.state.insert("notice".into(), Json::Null);
        if open {
            self.read_machines(engine);
            self.watch_access(engine);
            return;
        }
        if let Some(id) = self.access.take() {
            self.mc.unsubscribe(id);
        }
        self.pairing_links.clear();
        self.clients.clear();
        self.state.insert("access".into(), Json::Null);
        self.state.insert("accessError".into(), Json::Null);
        self.state.insert("created".into(), Json::Null);
        // And a link still on its way is not shown when it arrives.
        self.link_request += 1;
        self.publish(engine);
    }

    fn machines_changed(&mut self, engine: &Engine) {
        if self.open && self.read_machines(engine) {
            self.publish(engine);
        }
    }

    /// Reads the machines a pairing link can be for; true when they changed.
    fn read_machines(&mut self, engine: &Engine) -> bool {
        let scope = SettingsScope::of(engine);
        let machines: Vec<Json> = scope
            .listed(engine)
            .into_iter()
            .filter(|id| scope.online(engine, id))
            .map(|id| json!({"id": id, "label": scope.label(engine, &id)}))
            .collect();
        let machines = Json::Array(machines);
        if self.state.get("machines") == Some(&machines) {
            return false;
        }
        self.state.insert("machines".into(), machines);
        true
    }

    fn watch_access(&mut self, engine: &Engine) {
        if let Some(id) = self.access.take() {
            self.mc.unsubscribe(id);
        }
        self.state.insert("accessError".into(), Json::Null);
        self.state.insert("accessNeedsAdmin".into(), false.into());
        self.publish(engine);
        let me = self.me.clone();
        self.access = Some(self.mc.subscribe(
            json!({"type": "authAccess"}),
            Box::new(move |engine, frame| {
                me.run(engine, |c, engine| c.on_access(engine, frame));
            }),
            None,
        ));
    }

    fn on_access(&mut self, engine: &Engine, frame: &crate::mc::Frame) {
        let kind = frame.get("t").and_then(Json::as_str).unwrap_or_default();
        if kind == "error" {
            if let Some(id) = self.access.take() {
                self.mc.unsubscribe(id);
            }
            self.state.insert("access".into(), Json::Null);
            let reason = frame
                .get("reason")
                .and_then(Json::as_str)
                .unwrap_or_default();
            self.state
                .insert("accessNeedsAdmin".into(), lacks_admin(reason).into());
            self.set(engine, "accessError", explain(reason).into());
            return;
        }
        if kind != "authAccess" {
            return;
        }
        let event = frame.get("event").cloned().unwrap_or_default();
        let payload = event.get("payload").cloned().unwrap_or_default();
        let list_of = |key: &str| {
            payload
                .get(key)
                .and_then(Json::as_array)
                .cloned()
                .unwrap_or_default()
        };
        let same = |item: &Json, key: &str, value: Option<&Json>| item.get(key) == value;
        let upsert = |list: &mut Vec<Json>, key: &str| match list
            .iter()
            .position(|item| same(item, key, payload.get(key)))
        {
            Some(at) => list[at] = payload.clone(),
            None => list.push(payload.clone()),
        };
        match event.get("type").and_then(Json::as_str).unwrap_or_default() {
            "snapshot" => {
                self.pairing_links = list_of("pairingLinks");
                self.clients = list_of("clientSessions");
            }
            "pairingLinkUpserted" => upsert(&mut self.pairing_links, "id"),
            "pairingLinkRemoved" => {
                let id = payload.get("id");
                self.pairing_links.retain(|item| !same(item, "id", id));
            }
            "clientUpserted" => upsert(&mut self.clients, "sessionId"),
            "clientRemoved" => {
                let id = payload.get("sessionId");
                self.clients.retain(|item| !same(item, "sessionId", id));
            }
            _ => return,
        }
        let access = json!({"pairingLinks": self.pairing_links, "clients": self.clients});
        self.set(engine, "access", access);
    }

    fn create_pairing_link(&mut self, engine: &Engine, input: &Json) {
        let scopes: Vec<&str> = input
            .get("scopes")
            .and_then(Json::as_array)
            .map(|a| a.iter().filter_map(Json::as_str).collect())
            .unwrap_or_default();
        if scopes.is_empty() {
            self.set_notice(engine, "error", "Select at least one permission.");
            return;
        }
        let mut payload = json!({"scopes": scopes});
        let label = input
            .get("label")
            .and_then(Json::as_str)
            .unwrap_or_default()
            .trim();
        if !label.is_empty() {
            payload["label"] = label.into();
        }
        let tailscale = input.get("tailscale").and_then(Json::as_bool) == Some(true);
        if tailscale {
            payload["tailscale"] = true.into();
        }
        let own = self.mc.environment();
        let chosen = input
            .get("environmentId")
            .and_then(Json::as_str)
            .unwrap_or_default();
        let environment = if chosen.is_empty() {
            own.clone()
        } else {
            chosen.to_owned()
        };
        // A machine this shell reached over the network is reached there by
        // the next device too, and the MC may only know the loopback it
        // listens on (it sits behind Tailscale Serve or a proxy): the shell
        // names the address.
        let reached = self.mc.origin().as_deref().and_then(address_of);
        if environment == own
            && !tailscale
            && let Some(reached) = reached.as_ref().filter(|r| !loopback(r))
        {
            payload["baseUrl"] = text(reached).into();
        }
        self.link_request += 1;
        let request = self.link_request;
        let environment_id = environment.clone();
        self.change(
            engine,
            &environment,
            "hal-c2.createPairingLink",
            payload,
            Box::new(move |c, engine, result| {
                c.pairing_link_created(engine, &environment_id, &own, request, result);
            }),
            "Could not create the pairing URL",
        );
    }

    fn pairing_link_created(
        &mut self,
        engine: &Engine,
        environment: &str,
        own: &str,
        request: u64,
        result: &Json,
    ) {
        let said = |key: &str| {
            result
                .get(key)
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        let (code, id) = (said("credential"), said("id"));
        // The page was left since, or asked for another link: this one would
        // be shown to nobody, or on a visit that did not ask for it.
        if request != self.link_request {
            self.discard(environment, &id);
            self.publish(engine);
            return;
        }
        // The MC says where it is reached. One from before it did is reached
        // where this shell reached it, which says nothing of another machine.
        let mut address = said("address");
        let mut local_only = result.get("localOnly").and_then(Json::as_bool) == Some(true);
        if address.is_empty()
            && environment == own
            && let Some(origin) = self.mc.origin().as_deref().and_then(address_of)
        {
            address = text(&origin);
            local_only = loopback(&origin);
        }
        let machine = SettingsScope::of(engine).label(engine, environment);
        if address.is_empty() {
            // No one can use a link with no address.
            self.discard(environment, &id);
            self.set_notice(
                engine,
                "error",
                &format!(
                    "Could not create the pairing URL: {machine} did not say where it can be reached. Update HAL-C2 on it."
                ),
            );
            return;
        }
        let url = pairing_url(&address, &code);
        let qr = if local_only {
            qr::Code::default()
        } else {
            qr::encode(&url)
        };
        let qr = if qr.is_null() {
            Json::Null
        } else {
            json!({"modules": qr.size, "path": qr::path(&qr)})
        };
        self.state.insert(
            "created".into(),
            json!({
                "id": id,
                "label": said("label"),
                "code": code,
                "url": url,
                "expiresAt": said("expiresAt"),
                "environmentId": environment,
                "machine": machine,
                "elsewhere": environment != own,
                "localOnly": local_only,
                "qr": qr,
            }),
        );
        self.set_notice(
            engine,
            "success",
            "Pairing link created. Copy it now: it is shown only while this page is open.",
        );
    }

    /// Revokes a link nobody can use on the machine that made it, saying
    /// nothing: it is not left behind.
    fn discard(&self, environment: &str, id: &str) {
        self.mc.call(
            environment,
            "hal-c2.revokePairingLink",
            json!({"id": id}),
            Box::new(|_, _| {}),
        );
    }

    /// Calls `method` on the MC of `environment`; `done` gets the result, or
    /// the notice says why not.
    fn change(
        &mut self,
        engine: &Engine,
        environment: &str,
        method: &str,
        payload: Json,
        done: Done,
        failure: &'static str,
    ) {
        self.set(engine, "busy", true.into());
        let me = self.me.clone();
        self.mc.call(
            environment,
            method,
            payload,
            Box::new(move |engine, result| {
                me.run(engine, |c, engine| {
                    c.state.insert("busy".into(), false.into());
                    match result {
                        Err(error) => c.set_notice(
                            engine,
                            "error",
                            &format!("{failure}: {}", explain(&error.message)),
                        ),
                        Ok(result) => done(c, engine, &result),
                    }
                });
            }),
        );
    }

    fn set_notice(&mut self, engine: &Engine, kind: &str, text: &str) {
        self.set(engine, "notice", json!({"kind": kind, "text": text}));
    }

    fn set(&mut self, engine: &Engine, field: &str, value: Json) {
        self.state.insert(field.into(), value);
        self.publish(engine);
    }

    fn publish(&self, engine: &Engine) {
        if self.active {
            self.bridge
                .publish(engine, KEY, Json::Object(self.state.clone()));
        }
    }
}
