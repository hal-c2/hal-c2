//! `deviceSettings`, desktop-qt's DeviceSettingsController: Settings →
//! Integrations → Devices. The device hub and agent device access on the
//! settings scope's environments (`device.configure` on each), and the
//! device status of the scope's first connected environment, which says so
//! when several are selected. That environment's DeviceServiceState is
//! followed through the MC's `devices` shape when a cluster MC serves it,
//! and read with `device.list` otherwise. At a project scope the hub is the
//! environment's and only agent access changes, as the project's override.
//! The built-in browser's defaults have no native page: the desktop has no
//! embedded browser, and previews open in the user's own.
//!
//! Publishes `deviceSettings`: {open, projectScope, loaded, pending (hub |
//! agent | check | update-hub | update-agent | retry, "" when idle), busy
//! (the hub installing or starting), statusNote ("" unless several
//! environments are selected), hub and agent: {on, mixed, enabled (whether
//! it can be switched), version, status (what the switch is doing, or ""),
//! update ("Update to v<required>" when an update is offered, else "")},
//! canCheck, updateError: {tool, message} or null, platforms ([{platform,
//! ready, message}] once the hub is ready, else empty), hosts: [{id, label,
//! failed, message, canRetry}] (only hosts installing, starting or failed)}.
//!
//! Actions (`deviceSettings.`): `hub {enabled}` (turning it off turns agent
//! access off too), `agent {enabled}`, `check` (tool versions, installing
//! nothing), `refresh` (devices), `update {tool: hub | agent}`, `retry
//! {hostId}`.

use std::cell::RefCell;
use std::rc::Rc;

use ljos::prelude::Engine;
use serde_json::{Map, json};

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::navigation::at_section;
use crate::controllers::settings_scope::SettingsScope;
use crate::controllers::toasts::Toasts;
use crate::json::Json;
use crate::mc::{Mc, SubId};
use crate::store;

const KEY: &str = "deviceSettings";
const SECTION: &str = "/settings/integrations";
const HUB: &str = "enableDeviceSupport";
const AGENT: &str = "enableAgentDeviceAccess";

fn platform_name(platform: &str) -> &'static str {
    if platform == "ios" { "iOS" } else { "Android" }
}

fn text<'a>(value: &'a Json, field: &str) -> &'a str {
    value.get(field).and_then(Json::as_str).unwrap_or_default()
}

fn flag(value: &Json, field: &str) -> bool {
    value.get(field).and_then(Json::as_bool).unwrap_or(false)
}

fn numbers(version: &str) -> Vec<i64> {
    version
        .split('.')
        .map(|part| part.parse().unwrap_or(0))
        .collect()
}

/// DeviceToolVersions: the version running, else the required one when
/// installed, else the newest installed.
fn version_label(tools: &Json, kind: &str) -> String {
    let Some(tool) = tools.get(kind) else {
        return "Version unknown".into();
    };
    let running = text(tool, "runningVersion");
    if !running.is_empty() {
        return format!("v{running}");
    }
    let installed: Vec<&str> = tool
        .get("installedVersions")
        .and_then(Json::as_array)
        .map(|versions| versions.iter().filter_map(Json::as_str).collect())
        .unwrap_or_default();
    let required = text(tool, "requiredVersion");
    if installed.contains(&required) {
        return format!("v{required}");
    }
    match installed.iter().max_by_key(|v| numbers(v)) {
        Some(newest) => format!("v{newest}"),
        None => "Not installed".into(),
    }
}

/// What a switch is, to the page.
struct Toggle {
    on: bool,
    mixed: bool,
    enabled: bool,
    status: String,
    update: String,
    version: String,
}

impl Toggle {
    fn json(self) -> Json {
        json!({
            "on": self.on,
            "mixed": self.mixed,
            "enabled": self.enabled,
            "status": self.status,
            "update": self.update,
            "version": self.version,
        })
    }
}

/// A `device.configure` round: it ends when every environment has answered.
struct Round {
    left: usize,
    failed: Vec<String>,
}

pub struct DeviceSettings {
    bridge: Bridge,
    me: Me<DeviceSettings>,
    mc: Rc<dyn Mc>,
    active: bool,
    open: bool,
    environment_id: String,
    subscription: Option<SubId>,
    /// Bumped when the inspected environment changes, so older answers are
    /// dropped.
    generation: u64,
    request: u64,
    state: Json,
    loaded: bool,
    platforms_shown: bool,
    pending: String,
    /// The tool whose update failed, and what to tell.
    update_error: Option<(String, String)>,
}

impl Controller for DeviceSettings {
    fn new(init: Init<'_, Self>) -> Self {
        DeviceSettings {
            bridge: init.bridge,
            me: init.me,
            mc: init.mc,
            active: false,
            open: false,
            environment_id: String::new(),
            subscription: None,
            generation: 0,
            request: 0,
            state: Json::Null,
            loaded: false,
            platforms_shown: false,
            pending: String::new(),
            update_error: None,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let me = self.me.clone();
        self.bridge.watch(engine, "route", move |engine, route| {
            let open = at_section(route, SECTION);
            me.run(engine, |c, engine| {
                if open == c.open {
                    return;
                }
                c.open = open;
                c.follow(engine);
            });
        });
        let me = self.me.clone();
        SettingsScope::of(engine).on_changed(move |engine| {
            me.run(engine, |c, engine| c.follow(engine));
        });
        // A window restored on this page has its route before this activates.
        let route = self.bridge.published(engine, "route").unwrap_or(Json::Null);
        if at_section(&route, SECTION) {
            self.open = true;
            self.follow(engine);
        }
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        let Some(name) = action
            .strip_prefix(KEY)
            .and_then(|rest| rest.strip_prefix('.'))
        else {
            return false;
        };
        if !self.active {
            return false;
        }
        if !self.open || !self.pending.is_empty() {
            return true;
        }
        let scope = SettingsScope::of(engine);
        let enabled = flag(payload, "enabled");
        match name {
            "hub" => {
                if scope.project_scope() || self.busy() {
                    return true;
                }
                let change = if enabled {
                    json!({"enabled": true, "onboardingCompleted": true})
                } else {
                    json!({"enabled": false, "agentAccessEnabled": false})
                };
                self.configure(engine, "hub", change);
            }
            "agent" => {
                if scope.project_scope() {
                    scope.write(
                        engine,
                        move |settings, project_id| {
                            SettingsScope::with_override(
                                settings,
                                project_id,
                                AGENT,
                                Some(enabled.into()),
                            )
                        },
                        "",
                    );
                } else {
                    self.configure(engine, "agent", json!({"agentAccessEnabled": enabled}));
                }
            }
            "check" => self.list(engine, "check", json!({"inspectOnly": true}), None),
            "refresh" => self.list(engine, "check", json!({}), None),
            "update" => {
                let tool = text(payload, "tool");
                if tool != "hub" && tool != "agent" {
                    return true;
                }
                self.update_error = None;
                self.list(
                    engine,
                    &format!("update-{tool}"),
                    json!({"updateTool": tool}),
                    Some(tool.to_owned()),
                );
            }
            "retry" => self.list(
                engine,
                "retry",
                json!({"retryHostId": text(payload, "hostId")}),
                None,
            ),
            _ => {}
        }
        true
    }
}

impl DeviceSettings {
    /// The environment whose device status shows: the scope's first
    /// connected one.
    fn inspected(&self, engine: &Engine) -> String {
        if !self.open {
            return String::new();
        }
        SettingsScope::of(engine)
            .targets()
            .into_iter()
            .next()
            .unwrap_or_default()
    }

    fn busy(&self) -> bool {
        matches!(text(&self.state, "hostStatus"), "installing" | "starting")
    }

    fn follow(&mut self, engine: &Engine) {
        let environment_id = self.inspected(engine);
        if environment_id != self.environment_id {
            if let Some(id) = self.subscription.take() {
                self.mc.unsubscribe(id);
            }
            self.environment_id = environment_id.clone();
            self.state = Json::Null;
            self.loaded = false;
            self.platforms_shown = false;
            self.update_error = None;
            // A request in flight answers for the old environment: the
            // switches are free again.
            self.pending.clear();
            self.generation += 1;
            if !environment_id.is_empty() {
                let shape = json!({
                    "type": "devices",
                    "mc": store::with(engine, |s| s.mc_serving(&environment_id)),
                });
                let me = self.me.clone();
                self.subscription = Some(self.mc.subscribe(
                    shape,
                    Box::new(move |engine, frame| {
                        if frame.get("t").and_then(Json::as_str) != Some("devices") {
                            return;
                        }
                        let state = frame.get("state").cloned().unwrap_or_default();
                        me.run(engine, |c, engine| c.take(engine, state));
                    }),
                    None,
                ));
            }
        }
        self.publish(engine);
    }

    fn take(&mut self, engine: &Engine, state: Json) {
        self.state = state;
        self.loaded = true;
        self.publish(engine);
    }

    /// `device.list` on the inspected environment; its answer is the new
    /// state. `update_tool` names the tool whose update this is, which a
    /// failure is told for.
    fn list(&mut self, engine: &Engine, pending: &str, input: Json, update_tool: Option<String>) {
        if self.environment_id.is_empty() {
            return;
        }
        self.pending = pending.to_owned();
        let generation = self.generation;
        self.request += 1;
        let request = self.request;
        let me = self.me.clone();
        self.mc.call(
            &self.environment_id,
            "device.list",
            input,
            Box::new(move |engine, result| {
                me.run(engine, |c, engine| {
                    if c.generation != generation || c.request != request {
                        return;
                    }
                    c.pending.clear();
                    match result {
                        Err(_) => {
                            if let Some(tool) = update_tool {
                                c.update_error = Some((
                                    tool,
                                    "Update failed. Check this host's network connection and try again.".into(),
                                ));
                            }
                        }
                        Ok(state) => {
                            c.state = state;
                            c.loaded = true;
                        }
                    }
                    c.publish(engine);
                });
            }),
        );
        self.publish(engine);
    }

    /// `device.configure` on every selected environment; those that cannot
    /// be updated are named.
    fn configure(&mut self, engine: &Engine, pending: &str, change: Json) {
        let scope = SettingsScope::of(engine);
        let environments = scope.environments(engine);
        if environments.is_empty() || self.environment_id.is_empty() {
            return;
        }
        self.pending = pending.to_owned();
        self.request += 1;
        let request = self.request;
        let generation = self.generation;
        let (online, offline): (Vec<String>, Vec<String>) = environments
            .iter()
            .cloned()
            .partition(|id| scope.online(engine, id));
        if online.is_empty() {
            self.finish(engine, request, &environments, &offline);
            return;
        }
        let round = Rc::new(RefCell::new(Round {
            left: online.len(),
            failed: offline,
        }));
        for environment_id in online {
            let me = self.me.clone();
            let round = round.clone();
            let environments = environments.clone();
            let id = environment_id.clone();
            self.mc.call(
                &environment_id,
                "device.configure",
                change.clone(),
                Box::new(move |engine, result| {
                    let ok = result.is_ok();
                    let last = {
                        let mut round = round.borrow_mut();
                        if !ok {
                            round.failed.push(id.clone());
                        }
                        round.left -= 1;
                        round.left == 0
                    };
                    me.run(engine, |c, engine| {
                        if let Ok(state) = result
                            && id == c.environment_id
                            && generation == c.generation
                        {
                            c.state = state;
                            c.loaded = true;
                        }
                        if last {
                            let failed = round.borrow().failed.clone();
                            c.finish(engine, request, &environments, &failed);
                        }
                    });
                }),
            );
        }
        self.publish(engine);
    }

    /// Every environment has answered. Only the latest request frees the
    /// switches (`follow` already did for older ones).
    fn finish(
        &mut self,
        engine: &Engine,
        request: u64,
        environments: &[String],
        failed: &[String],
    ) {
        if self.request == request {
            self.pending.clear();
        }
        if !failed.is_empty() {
            let scope = SettingsScope::of(engine);
            let labels: Vec<String> = environments
                .iter()
                .filter(|id| failed.contains(id))
                .map(|id| scope.label(engine, id))
                .collect();
            let description = format!("Could not update {}.", labels.join(", "));
            Bridge::of(engine).defer(engine, move |engine| {
                controller::with::<Toasts, _>(engine, |toasts, engine| {
                    toasts.error(
                        engine,
                        "Device settings not saved on all environments",
                        &description,
                    );
                });
            });
        }
        self.publish(engine);
    }

    fn toggle(
        &self,
        engine: &Engine,
        key: &'static str,
        enabled: bool,
        status: String,
        update: String,
        version: String,
    ) -> Json {
        let scope = SettingsScope::of(engine);
        let reading = scope.read(|settings, project_id| {
            let mut value = settings.get(key).cloned();
            if !project_id.is_empty()
                && let Some(own) = SettingsScope::override_of(settings, project_id, key)
            {
                value = Some(own);
            }
            Some(Json::Bool(value.and_then(|v| v.as_bool()).unwrap_or(false)))
        });
        Toggle {
            on: reading.value.and_then(|v| v.as_bool()).unwrap_or(false),
            mixed: reading.mixed,
            enabled: enabled && scope.editable(engine),
            status,
            update,
            version,
        }
        .json()
    }

    /// The switch's progress while it is being changed (DeviceHubSetupStatus
    /// and AgentDeviceSetupStatus, compact), or "".
    fn progress(&self, pending: &str) -> String {
        if self.pending != pending {
            return String::new();
        }
        match text(&self.state, "hostStatus") {
            "installing" => "Installing…",
            "starting" => "Starting…",
            _ => "Updating…",
        }
        .into()
    }

    fn local_host(&self) -> Json {
        self.state
            .get("hosts")
            .and_then(Json::as_array)
            .and_then(|hosts| hosts.iter().find(|h| text(h, "kind") == "local"))
            .cloned()
            .unwrap_or(Json::Null)
    }

    fn update_label(&self, tools: &Json, kind: &str) -> String {
        if !flag(&self.state, "supportsToolUpdate") {
            return String::new();
        }
        let Some(tool) = tools.get(kind) else {
            return String::new();
        };
        let required = text(tool, "requiredVersion");
        let installed = tool
            .get("installedVersions")
            .and_then(Json::as_array)
            .is_some_and(|v| v.iter().any(|v| v.as_str() == Some(required)));
        if installed {
            String::new()
        } else {
            format!("Update to v{required}")
        }
    }

    /// platformSetupStatus.
    fn platform(&self, platform: &str) -> Json {
        let availability = self
            .state
            .get("hosts")
            .and_then(Json::as_array)
            .into_iter()
            .flatten()
            .flat_map(|host| {
                host.get("platforms")
                    .and_then(Json::as_array)
                    .into_iter()
                    .flatten()
            })
            .find(|entry| text(entry, "platform") == platform)
            .cloned()
            .unwrap_or(Json::Null);
        let name = platform_name(platform);
        if !flag(&availability, "available") {
            let reason = availability.get("reason").and_then(Json::as_str);
            return json!({
                "platform": name,
                "ready": false,
                "message": reason.map_or_else(|| format!("{name} support was not detected."), str::to_owned),
            });
        }
        let any = self
            .state
            .get("devices")
            .and_then(Json::as_array)
            .is_some_and(|devices| devices.iter().any(|d| text(d, "platform") == platform));
        let ios = platform == "ios";
        if text(&self.state, "hostStatus") == "ready" && !any {
            return json!({
                "platform": name,
                "ready": false,
                "message": if ios {
                    "Xcode is installed, but no iOS Simulator is available. Install a runtime in Xcode Settings → Components."
                } else {
                    "The Android SDK is installed, but no virtual device exists. Create one in Android Studio → Device Manager."
                },
            });
        }
        json!({
            "platform": name,
            "ready": true,
            "message": if ios {
                "Xcode and iOS Simulator are available."
            } else {
                "The Android SDK and Emulator are available."
            },
        })
    }

    /// DeviceHostUpdates: the local host while its tools install, start or
    /// fail.
    fn hosts(&self) -> Vec<Json> {
        if text(&self.state, "hostStatus") == "disabled" {
            return Vec::new();
        }
        let host = self.local_host();
        let id = text(&host, "id");
        let status = self
            .state
            .get("hostStatuses")
            .and_then(|s| s.get(id))
            .cloned()
            .unwrap_or(Json::Null);
        let value = text(&status, "status");
        if host.is_null() || !matches!(value, "installing" | "starting" | "failed") {
            return Vec::new();
        }
        let failed = value == "failed";
        let fallback = match value {
            "failed" => "Device support could not start.",
            "installing" => "Installing device tools…",
            _ => "Starting device tools…",
        };
        vec![json!({
            "id": id,
            "label": text(&host, "label"),
            "failed": failed,
            "message": status.get("detail").and_then(Json::as_str).unwrap_or(fallback),
            "canRetry": failed && flag(&self.state, "supportsHostRetry"),
        })]
    }

    fn publish(&mut self, engine: &Engine) {
        if !self.active {
            return;
        }
        if !self.open {
            self.bridge.publish(engine, KEY, json!({"open": false}));
            return;
        }
        let scope = SettingsScope::of(engine);
        let project = scope.project_scope();
        let hub_on = scope
            .read(|settings, _| Some(Json::Bool(flag(&Json::Object(settings.clone()), HUB))))
            .value
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        // Diagnostics stay once the hub was ready, through later agent setup.
        if !hub_on {
            self.platforms_shown = false;
        } else if text(&self.state, "hostStatus") == "ready" && self.pending != "hub" {
            self.platforms_shown = true;
        }
        let targets = scope.targets();
        let any_hub = targets.iter().any(|id| {
            scope
                .settings(id)
                .is_some_and(|s| flag(&Json::Object(s), HUB))
        });
        let idle = self.pending.is_empty();
        let connected = !self.environment_id.is_empty();
        let tools = self
            .local_host()
            .get("tools")
            .cloned()
            .unwrap_or(Json::Null);
        let busy = self.busy();

        let hub = self.toggle(
            engine,
            HUB,
            !project && self.loaded && connected && !busy && idle,
            self.progress("hub"),
            self.update_label(&tools, "hub"),
            version_label(&tools, "hub"),
        );
        let agent = self.toggle(
            engine,
            AGENT,
            !targets.is_empty() && (project || (self.loaded && any_hub && !busy)) && idle,
            self.progress("agent"),
            self.update_label(&tools, "agent"),
            version_label(&tools, "agent"),
        );
        let platforms = if self.platforms_shown {
            vec![self.platform("ios"), self.platform("android")]
        } else {
            Vec::new()
        };
        let status_note = if targets.len() > 1 {
            format!(
                "Status for {}. Select an environment to inspect its simulator support.",
                scope.label(engine, &self.environment_id)
            )
        } else {
            String::new()
        };
        let update_error = match &self.update_error {
            Some((tool, message)) => json!({"tool": tool, "message": message}),
            None => Json::Null,
        };
        let mut state = Map::new();
        state.insert("open".into(), true.into());
        state.insert("projectScope".into(), project.into());
        state.insert("loaded".into(), self.loaded.into());
        state.insert("pending".into(), self.pending.clone().into());
        state.insert("busy".into(), busy.into());
        state.insert("statusNote".into(), status_note.into());
        state.insert("hub".into(), hub);
        state.insert("agent".into(), agent);
        state.insert(
            "canCheck".into(),
            (connected && flag(&self.state, "supportsToolInspection")).into(),
        );
        state.insert("updateError".into(), update_error);
        state.insert("platforms".into(), platforms.into());
        state.insert("hosts".into(), self.hosts().into());
        self.bridge.publish(engine, KEY, Json::Object(state));
    }
}
