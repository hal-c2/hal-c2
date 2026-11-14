//! The runtime the MC installs itself (Antigravity) on its Providers card:
//! each such instance follows its MC-addressed `providerInstall` shape, so
//! every client shows the same download.
//!
//! Actions: `providerSettings.runtimeInstall {instanceId}`, `.runtimeCancel
//! {instanceId}`, `.runtimeRemove {instanceId}` (asks first).
//!
//! Each such entry's `runtime`: null until the MC reports it, else {status,
//! message, progress (0..1, or -1 without a known size), installLabel (""
//! when it cannot install), canCancel, canRemove, busy, error}.

use ljos::prelude::Engine;
use serde_json::json;

use super::{ProviderSettings, at, bool_at, confirm, error_text, str_at};
use crate::json::Json;

/// Whether the MC installs this provider's runtime itself.
fn manages(provider: &Json) -> bool {
    str_at(provider, "driver") == "antigravity"
}

fn running(state: &Json) -> bool {
    matches!(
        str_at(state, "phase"),
        "downloading" | "extracting" | "verifying"
    )
}

fn megabytes(bytes: f64) -> String {
    format!("{:.1}", bytes / 1_000_000.0)
}

impl ProviderSettings {
    /// Follows the install of each runtime the MC manages, on the MC serving
    /// the environment.
    pub(super) fn follow_runtime(&mut self, engine: &Engine) {
        let (mc, wanted) = self.wanted(engine, manages);
        let dropped: Vec<String> = self
            .install
            .keys()
            .filter(|id| !wanted.contains(id))
            .cloned()
            .collect();
        for id in dropped {
            if let Some(sub) = self.install.remove(&id) {
                self.mc.unsubscribe(sub);
            }
            self.install_state.remove(&id);
        }
        for id in wanted {
            if self.install.contains_key(&id) {
                continue;
            }
            let me = self.me.clone();
            let instance_id = id.clone();
            let sub = self.mc.subscribe(
                json!({"type": "providerInstall", "mc": mc, "instanceId": id}),
                Box::new(move |engine, frame| {
                    if frame.get("t").and_then(Json::as_str) != Some("providerInstall") {
                        return;
                    }
                    let state = frame
                        .get("state")
                        .filter(|s| s.is_object())
                        .cloned()
                        .unwrap_or_else(|| json!({}));
                    let instance_id = instance_id.clone();
                    me.run(engine, move |c, engine| {
                        c.install_state.insert(instance_id, state);
                        c.publish(engine);
                    });
                }),
                None,
            );
            self.install.insert(id, sub);
        }
    }

    pub(super) fn unfollow_runtime(&mut self) {
        for (_, sub) in self.install.drain() {
            self.mc.unsubscribe(sub);
        }
        self.install_state.clear();
        self.install_error.clear();
    }

    pub(super) fn handle_runtime(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !matches!(
            action,
            "providerSettings.runtimeInstall"
                | "providerSettings.runtimeCancel"
                | "providerSettings.runtimeRemove"
        ) {
            return false;
        }
        let instance_id = str_at(payload, "instanceId").to_owned();
        let Some(state) = self.install_state.get(&instance_id).cloned() else {
            return true;
        };
        if self.busy.contains(&instance_id) {
            return true;
        }
        match action {
            "providerSettings.runtimeInstall" => {
                self.runtime_call(
                    engine,
                    &instance_id,
                    "provider.install.start",
                    json!({"instanceId": instance_id}),
                );
            }
            "providerSettings.runtimeCancel" => {
                let operation_id = str_at(&state, "operationId");
                if !running(&state) || operation_id.is_empty() {
                    return true;
                }
                self.runtime_call(
                    engine,
                    &instance_id,
                    "provider.install.cancel",
                    json!({"instanceId": instance_id, "operationId": operation_id}),
                );
            }
            _ => {
                if running(&state) || !bool_at(&state, "canRemove") {
                    return true;
                }
                let environment = self.followed.clone();
                let description = format!(
                    "Remove the downloaded Antigravity runtime from {}? Google sign-in and thread history are kept.",
                    self.label(engine, &environment)
                );
                confirm(
                    engine,
                    &self.me,
                    "Remove runtime?",
                    &description,
                    "Remove",
                    move |c, engine| {
                        // The answer may come after the user moved on.
                        if c.followed != environment {
                            return;
                        }
                        c.runtime_call(
                            engine,
                            &instance_id,
                            "provider.install.remove",
                            json!({"instanceId": instance_id}),
                        );
                    },
                );
            }
        }
        true
    }

    fn runtime_call(&mut self, engine: &Engine, instance_id: &str, method: &str, payload: Json) {
        if self.busy.contains(instance_id) || self.followed.is_empty() {
            return;
        }
        self.busy.insert(instance_id.to_owned());
        self.install_error.remove(instance_id);
        self.publish(engine);
        let following = self.following;
        let me = self.me.clone();
        let id = instance_id.to_owned();
        self.mc.call(
            &self.followed,
            method,
            payload,
            Box::new(move |engine, result| {
                me.run(engine, move |c, engine| {
                    if c.following != following {
                        return;
                    }
                    c.busy.remove(&id);
                    if let Err(error) = result {
                        c.install_error
                            .insert(id, error_text(&error, "Provider setup failed. Try again."));
                    }
                    c.publish(engine);
                });
            }),
        );
    }

    /// A managed runtime's entry (ProviderSetupSection).
    pub(super) fn runtime_entry(&self, provider: &Json) -> Json {
        let instance_id = str_at(provider, "instanceId");
        let Some(state) = self
            .install_state
            .get(instance_id)
            .filter(|_| manages(provider))
        else {
            return Json::Null;
        };
        let phase = str_at(state, "phase");
        let active = running(state);
        let downloaded = at(state, "downloadedBytes").as_f64().unwrap_or(0.0);
        let total = at(state, "totalBytes").as_f64().unwrap_or(0.0);
        let installed_version = str_at(state, "installedVersion");
        let version = str_at(state, "version");
        let installed = bool_at(provider, "installed") || !installed_version.is_empty();
        let status = match phase {
            "downloading" if total > 0.0 => format!(
                "Downloading {} MB of {} MB.",
                megabytes(downloaded),
                megabytes(total)
            ),
            "downloading" => format!("Downloading {} MB.", megabytes(downloaded)),
            "extracting" => "Extracting Antigravity.".into(),
            "verifying" => "Checking the downloaded runtime.".into(),
            _ if installed => "Installed.".into(),
            _ if total > 0.0 => format!("{} MB download.", (total / 1_000_000.0).ceil() as i64),
            _ => "Not installed.".into(),
        };
        let message = str_at(state, "message");
        let install_label = if active || !bool_at(at(provider, "setup"), "canInstall") {
            ""
        } else if !installed_version.is_empty() {
            if !version.is_empty() && version != installed_version {
                "Update Antigravity"
            } else {
                "Reinstall Antigravity"
            }
        } else if phase == "failed" || phase == "cancelled" {
            "Retry installation"
        } else if installed {
            "Install managed runtime"
        } else {
            "Install Antigravity"
        };
        json!({
            "status": status,
            "message": if !active && message != status { message } else { "" },
            "progress": if phase == "downloading" && total > 0.0 { (downloaded / total).min(1.0) } else { -1.0 },
            "installLabel": install_label,
            "canCancel": active && !str_at(state, "operationId").is_empty(),
            "canRemove": !active && bool_at(state, "canRemove"),
            "busy": self.busy.contains(instance_id),
            "error": self.install_error.get(instance_id).cloned().unwrap_or_default(),
        })
    }
}
