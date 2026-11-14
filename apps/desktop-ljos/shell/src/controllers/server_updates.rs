//! `serverUpdates`, desktop-qt's ServerUpdateController (ServerUpdates
//! holds the rules): bringing the cluster's servers up to this app's
//! version. A server behind the app is updated by the path its
//! descriptor offers (`capabilities.serverSelfUpdate`): it updates
//! itself (`server.updateServer`), a desktop app runs it and this
//! client can have that app update (`desktopAppUpdate` — the app closes
//! and relaunches, so the user confirms first), only that machine can
//! update it, or it was started by hand and the user runs a command
//! there. One update per server at a time; Update all starts every
//! server that can update from here at once, asking once before any
//! desktop app relaunches.
//!
//! The machines come from the shell store's descriptors, the app's
//! version from ConnectionHealth, and the effects are the MC call, the
//! shell's one confirmation, its toasts and the clipboard.
//!
//! Publishes `serverUpdates`: {appVersion, machines: [{environmentId,
//! label, version, online, behind, path, command, updating}],
//! updatable}.
//!
//! Actions: `serverUpdates.update {environmentId}`,
//! `serverUpdates.copyCommand {environmentId}`,
//! `serverUpdates.updateAll`. The palette has "Update all servers" and
//! "Update a server..." while one is behind.

use std::collections::HashSet;
use std::rc::Rc;

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::commands::{Choice, Commands};
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::connection_health::{ConnectionHealth, server_behind};
use crate::controllers::menus::Menus;
use crate::controllers::toasts::Toasts;
use crate::json::Json;
use crate::mc::Mc;
use crate::settings_page;
use crate::store;

const UPDATE_ALL: &str = "serverUpdates.updateAll";
const UPDATE_ONE: &str = "serverUpdates.update";

#[derive(Clone)]
struct Machine {
    id: String,
    label: String,
    version: String,
    /// `serverSelfUpdate`, empty when the server cannot update itself.
    self_update: String,
    desktop_app_update: bool,
    online: bool,
}

/// update, desktop, desktop-manual or command.
fn path(machine: &Machine) -> &'static str {
    if machine.self_update.is_empty() {
        return "command";
    }
    if machine.self_update != "desktop-managed" {
        return "update";
    }
    if machine.desktop_app_update {
        "desktop"
    } else {
        "desktop-manual"
    }
}

/// The command that updates a server started by hand.
fn command(target_version: &str) -> String {
    format!("npx hal-c2@{target_version}")
}

pub struct ServerUpdates {
    bridge: Bridge,
    me: Me<ServerUpdates>,
    mc: Rc<dyn Mc>,
    app_version: String,
    machines: Vec<Machine>,
    updating: HashSet<String>,
    active: bool,
}

impl Controller for ServerUpdates {
    fn new(init: Init<'_, Self>) -> Self {
        ServerUpdates {
            bridge: init.bridge,
            me: init.me,
            mc: init.mc,
            app_version: String::new(),
            machines: Vec::new(),
            updating: HashSet::new(),
            active: false,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        self.active = true;
        let me = self.me.clone();
        store::on_changed(engine, move |engine: &Engine| {
            me.run(engine, |c, engine| c.refresh(engine));
        });
        self.refresh(engine);
    }

    fn attach(&mut self, engine: &Engine, _window: &crate::controller::Window) {
        let commands = Commands::of(engine);
        commands.add(engine, UPDATE_ALL, "Update all servers", |engine| {
            controller::with::<ServerUpdates, _>(engine, |c, engine| {
                c.update_all(engine);
                c.publish(engine);
            });
        });
        commands.add_menu(engine, UPDATE_ONE, "Update a server...", |engine| {
            controller::with::<ServerUpdates, _>(engine, |c, _| {
                let mut choices = Vec::new();
                for machine in &c.machines {
                    let way = path(machine);
                    if !machine.online || !c.behind(machine) || way == "desktop-manual" {
                        continue;
                    }
                    let id = machine.id.clone();
                    let mut choice = Choice::new(&machine.id, &machine.label, move |engine| {
                        let id = id.clone();
                        controller::with::<ServerUpdates, _>(engine, move |c, engine| {
                            c.update(engine, &id);
                            c.publish(engine);
                        });
                    });
                    choice.description = if way == "command" {
                        format!("Copy the update command (on {})", machine.version)
                    } else {
                        format!("On {}", machine.version)
                    };
                    choice.enabled = !c.updating.contains(&machine.id);
                    choices.push(choice);
                }
                choices
            })
            .unwrap_or_default()
        });
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !action.starts_with("serverUpdates.") {
            return false;
        }
        let environment_id = settings_page::text(payload, "environmentId").to_owned();
        match action {
            UPDATE_ONE => self.update(engine, &environment_id),
            "serverUpdates.copyCommand" => self.copy_command(engine, &environment_id),
            UPDATE_ALL => self.update_all(engine),
            _ => return false,
        }
        self.publish(engine);
        true
    }
}

impl ServerUpdates {
    fn behind(&self, machine: &Machine) -> bool {
        server_behind(&self.app_version, &machine.version)
    }

    fn find(&self, environment_id: &str) -> Option<Machine> {
        self.machines
            .iter()
            .find(|machine| machine.id == environment_id)
            .cloned()
    }

    /// The servers Update all reaches now: online, behind, updatable
    /// from here and not already updating.
    fn updatable(&self) -> Vec<Machine> {
        self.machines
            .iter()
            .filter(|machine| {
                let way = path(machine);
                machine.online
                    && self.behind(machine)
                    && !self.updating.contains(&machine.id)
                    && (way == "update" || way == "desktop")
            })
            .cloned()
            .collect()
    }

    fn toast(&self, engine: &Engine, kind: &str, title: &str, description: &str) {
        let (kind, title, description) =
            (kind.to_owned(), title.to_owned(), description.to_owned());
        controller::with::<Toasts, _>(engine, move |t, e| {
            t.show(
                e,
                &kind,
                &title,
                &description,
                None,
                crate::controllers::toasts::DEFAULT_TIMEOUT_MS,
            );
        });
    }

    fn confirm(
        &mut self,
        engine: &Engine,
        title: String,
        description: &str,
        accepted: impl Fn(&mut ServerUpdates, &Engine) + 'static,
    ) {
        let me = self.me.clone();
        let accepted = Rc::new(accepted);
        controller::with::<Menus, _>(engine, move |menus, engine| {
            menus.confirm(
                engine,
                &title,
                description,
                "Update",
                false,
                Some(Rc::new(move |engine: &Engine| {
                    let accepted = accepted.clone();
                    me.run(engine, move |c, engine| {
                        accepted(c, engine);
                        c.publish(engine);
                    });
                })),
                None,
            );
        });
    }

    /// The user chose the offer for `environment_id`: updates it, asks
    /// first for a desktop app, or copies the command. Nothing for a
    /// server not behind, one already updating, or one only its own
    /// machine can update.
    fn update(&mut self, engine: &Engine, environment_id: &str) {
        let Some(machine) = self.find(environment_id) else {
            return;
        };
        if !machine.online || !self.behind(&machine) || self.updating.contains(environment_id) {
            return;
        }
        match path(&machine) {
            "command" => self.copy_command(engine, environment_id),
            "update" => self.run(engine, &machine, "Server update failed".into()),
            "desktop" => {
                // The only question in the flow: the machine that runs it
                // installs without asking anyone there.
                let id = environment_id.to_owned();
                self.confirm(
                    engine,
                    format!("Update the HAL-C2 desktop app that runs {}?", machine.label),
                    "It will close and relaunch on that machine.",
                    move |c, engine| {
                        if let Some(now) = c.find(&id)
                            && !c.updating.contains(&id)
                        {
                            c.run(engine, &now, "Server update failed".into());
                        }
                    },
                );
            }
            _ => {}
        }
    }

    fn update_all(&mut self, engine: &Engine) {
        let eligible = self.updatable();
        if eligible.is_empty() {
            return;
        }
        let desktops: Vec<String> = eligible
            .iter()
            .filter(|machine| path(machine) == "desktop")
            .map(|machine| machine.label.clone())
            .collect();
        let ids: Vec<String> = eligible.iter().map(|machine| machine.id.clone()).collect();
        let start = move |c: &mut ServerUpdates, engine: &Engine| {
            for id in &ids {
                if let Some(machine) = c.find(id)
                    && !c.updating.contains(id)
                {
                    let title = format!("{} update failed", machine.label);
                    c.run(engine, &machine, title);
                }
            }
        };
        if desktops.is_empty() {
            start(self, engine);
            return;
        }
        self.confirm(
            engine,
            format!("Update the HAL-C2 desktop apps on {}?", desktops.join(", ")),
            "They will close and relaunch on those machines.",
            start,
        );
    }

    fn copy_command(&mut self, engine: &Engine, environment_id: &str) {
        let Some(machine) = self.find(environment_id) else {
            return;
        };
        if self.app_version.is_empty() {
            return;
        }
        let text = command(&self.app_version);
        if self.bridge.copy_to_clipboard(engine, &text) {
            self.toast(
                engine,
                "success",
                "Update command copied",
                &format!("Run `{text}` on {} to update it.", machine.label),
            );
        } else {
            self.toast(
                engine,
                "error",
                "Could not copy update command",
                &format!(
                    "The clipboard could not be written. Run `{text}` on {} to update it.",
                    machine.label
                ),
            );
        }
    }

    fn run(&mut self, engine: &Engine, machine: &Machine, failure_title: String) {
        self.updating.insert(machine.id.clone());
        let (id, label) = (machine.id.clone(), machine.label.clone());
        let desktop = machine.self_update == "desktop-managed";
        let target = self.app_version.clone();
        let me = self.me.clone();
        let environment = id.clone();
        self.mc.call(
            &environment,
            "server.updateServer",
            json!({"targetVersion": target}),
            Box::new(move |engine, result| {
                let (ok, version, error) = match &result {
                    Ok(value) => (
                        true,
                        value
                            .get("targetVersion")
                            .and_then(Json::as_str)
                            .unwrap_or_default()
                            .to_owned(),
                        String::new(),
                    ),
                    Err(error) => (false, String::new(), error.message.clone()),
                };
                let id = id.clone();
                let (label, target, failure_title) =
                    (label.clone(), target.clone(), failure_title.clone());
                me.run(engine, move |c, engine| {
                    c.updating.remove(&id);
                    if !ok {
                        c.toast(
                            engine,
                            "error",
                            &failure_title,
                            if error.is_empty() {
                                "Server update failed."
                            } else {
                                &error
                            },
                        );
                    } else {
                        let version = if version.is_empty() {
                            &target
                        } else {
                            &version
                        };
                        let description = if desktop {
                            format!("Desktop app relaunched on {version}.")
                        } else {
                            format!("Reconnected on hal-c2@{version}.")
                        };
                        c.toast(engine, "success", &format!("{label} updated"), &description);
                    }
                    c.publish(engine);
                });
            }),
        );
        let _ = engine;
    }

    fn state(&self) -> Json {
        let machines: Vec<Json> = self
            .machines
            .iter()
            .map(|machine| {
                json!({
                    "environmentId": machine.id,
                    "label": machine.label,
                    "version": machine.version,
                    "online": machine.online,
                    "behind": self.behind(machine),
                    "path": path(machine),
                    "command": if self.app_version.is_empty() {
                        String::new()
                    } else {
                        command(&self.app_version)
                    },
                    "updating": self.updating.contains(&machine.id),
                })
            })
            .collect();
        json!({
            "appVersion": self.app_version,
            "machines": machines,
            "updatable": self.updatable().len(),
        })
    }

    /// Re-reads the app's version and the machines as the store describes
    /// them, this shell's own first; runs on each store change, and when a
    /// test sets the app's version.
    pub fn refresh(&mut self, engine: &Engine) {
        // The app's version is the health controller's, which tests may set.
        self.app_version =
            controller::with::<ConnectionHealth, _>(engine, |health, _| health.client_version())
                .unwrap_or_else(|| env!("CARGO_PKG_VERSION").to_owned())
                .trim()
                .to_owned();
        self.machines = store::with(engine, |store| {
            let mut ids = store.environments();
            let own = self.mc.environment();
            if !own.is_empty() {
                ids.retain(|id| id != &own);
                ids.insert(0, own);
            }
            ids.iter()
                .map(|id| {
                    let descriptor = store.environment(id);
                    let capabilities = descriptor
                        .get("capabilities")
                        .cloned()
                        .unwrap_or(Json::Null);
                    let text = |value: &Json| value.as_str().unwrap_or_default().to_owned();
                    let mut label = text(descriptor.get("label").unwrap_or(&Json::Null));
                    if label.is_empty() {
                        label.clone_from(id);
                    }
                    Machine {
                        id: id.clone(),
                        label,
                        version: text(descriptor.get("serverVersion").unwrap_or(&Json::Null)),
                        self_update: text(&capabilities["serverSelfUpdate"]),
                        desktop_app_update: capabilities["desktopAppUpdate"]
                            .as_bool()
                            .unwrap_or(false),
                        online: store.environment_online(id),
                    }
                })
                .collect()
        });
        self.publish(engine);
    }

    fn publish(&self, engine: &Engine) {
        if !self.active {
            return;
        }
        self.bridge.publish(engine, "serverUpdates", self.state());
        let behind = self.machines.iter().any(|machine| {
            machine.online && self.behind(machine) && path(machine) != "desktop-manual"
        });
        let updatable = !self.updatable().is_empty();
        let commands = Commands::of(engine);
        commands.set_enabled(engine, UPDATE_ALL, updatable);
        commands.set_listed(engine, UPDATE_ALL, updatable);
        commands.set_enabled(engine, UPDATE_ONE, behind);
        commands.set_listed(engine, UPDATE_ONE, behind);
    }
}
