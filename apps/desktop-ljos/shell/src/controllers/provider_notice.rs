//! `providerNotice`, desktop-qt's ProviderNoticeController: what the
//! open thread's provider says when it cannot run a turn, as the web's
//! ProviderStatusBanner showed it over the timeline
//! (features/timeline/runs-and-queue.feature): not installed, signed
//! out, unavailable, or a version known to fail mid-turn even when
//! ready. The thread's provider is its row's
//! `modelSelection.instanceId`, read from the providers of the
//! environment it runs on. Dismissing hides that problem of that
//! provider until the app restarts; when the problem changes (another
//! status, sign-in state or message) it shows again.
//!
//! Publishes `providerNotice`: null, or {threadKey, instanceId, title,
//! message, warning, setup}; setup when provider setup can install or
//! sign it in.
//!
//! Actions: `providerNotice.dismiss` hides the open thread's notice;
//! `providerNotice.setup` opens Settings › Providers.

use std::collections::HashSet;

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{Controller, Init, Me};
use crate::controllers::navigation::{self, Navigation, PROVIDERS_SECTION, Route};
use crate::controllers::workspace;
use crate::json::Json;
use crate::store;
use serde_json::Map as JsonMap;

pub struct ProviderNotice {
    bridge: Bridge,
    me: Me<ProviderNotice>,
    active: bool,
    dismissed: HashSet<String>,
}

#[derive(Default)]
struct Notice {
    key: String,
    title: String,
    message: String,
    warning: bool,
    setup: bool,
}

fn later(
    engine: &Engine,
    me: &Me<ProviderNotice>,
    f: impl FnOnce(&mut ProviderNotice, &Engine) + 'static,
) {
    let me = me.clone();
    Bridge::of(engine).defer(engine, move |engine| me.run(engine, f));
}

fn open_key(engine: &Engine) -> String {
    match navigation::shown(engine) {
        Route::Thread(key) => key,
        _ => String::new(),
    }
}

fn text<'a>(object: &'a JsonMap<String, Json>, name: &str) -> &'a str {
    object
        .get(name)
        .and_then(Json::as_str)
        .map(str::trim)
        .unwrap_or("")
}

/// packages/contracts PROVIDER_DISPLAY_NAMES.
fn driver_name(driver: &str) -> &str {
    match driver {
        "antigravity" => "Antigravity",
        "codex" => "Codex",
        "claudeAgent" => "Claude",
        "cursor" => "Cursor",
        "grok" => "Grok",
        "acpRegistry" => "ACP Registry",
        "pi" => "Pi",
        "muse" => "Muse Code",
        "opencode" => "OpenCode",
        other => other,
    }
}

fn notice_of(provider: &JsonMap<String, Json>) -> Notice {
    let status = text(provider, "status");
    if provider.is_empty() || status.is_empty() || status == "disabled" {
        return Notice::default();
    }
    let driver = text(provider, "driver");
    let instance_id = text(provider, "instanceId");
    let version = text(provider, "version");
    let message = text(provider, "message");
    let auth = provider
        .get("auth")
        .and_then(Json::as_object)
        .map(|auth| text(auth, "status"))
        .unwrap_or("");
    let installed = provider
        .get("installed")
        .and_then(Json::as_bool)
        .unwrap_or(false);
    let display_name = text(provider, "displayName");
    let driver_label = driver_name(driver);
    let name = if display_name.is_empty() {
        driver_label
    } else {
        display_name
    };
    // Unsupported and broken versions fail mid-turn, so they warn even
    // when ready.
    let compatibility = provider
        .get("compatibilityAdvisory")
        .and_then(Json::as_object);
    let incompatible = compatibility.map(|c| text(c, "status")).unwrap_or("");
    let incompatible_version = matches!(incompatible, "unsupported" | "broken");
    let setup = provider.get("setup").and_then(Json::as_object);
    let flag = |field: &str| {
        setup
            .and_then(|s| s.get(field))
            .and_then(Json::as_bool)
            .unwrap_or(false)
    };
    let can_set_up = driver == "antigravity" || flag("canAuthenticate") || flag("canInstall");
    if status == "ready" {
        if !incompatible_version {
            return Notice::default();
        }
        let advice = compatibility.map(|c| text(c, "message")).unwrap_or("");
        return Notice {
            key: format!("{instance_id}\u{0}{incompatible}\u{0}{version}"),
            title: format!(
                "{name} {version} is {}",
                if incompatible == "broken" {
                    "known to be broken"
                } else {
                    "unsupported"
                }
            ),
            message: if !advice.is_empty() {
                advice.to_owned()
            } else if !message.is_empty() {
                message.to_owned()
            } else {
                "No models are available for this provider.".to_owned()
            },
            warning: true,
            setup: can_set_up,
        };
    }
    // Antigravity checks saved credentials when a session starts. Its
    // local health check leaves auth unknown after a restart, which is
    // not a failure.
    if driver == "antigravity" && installed && status == "warning" && auth == "unknown" {
        return Notice::default();
    }
    let said = if !message.is_empty() {
        message.to_owned()
    } else if !installed && can_set_up {
        format!("Open provider setup to install {driver_label} on this environment.")
    } else if auth == "unauthenticated" {
        if !can_set_up {
            "Sign in via the CLI to authenticate again.".to_owned()
        } else if driver == "antigravity" {
            "Open provider setup to sign in with Google.".to_owned()
        } else {
            "Open provider setup to sign in.".to_owned()
        }
    } else if status == "error" {
        format!("{name} provider is unavailable.")
    } else {
        format!("{name} provider has limited availability.")
    };
    let unauthenticated = status == "error" && auth == "unauthenticated";
    Notice {
        key: format!("{instance_id}\u{0}{status}\u{0}{auth}\u{0}{message}"),
        title: if unauthenticated {
            format!("{name} is unauthenticated")
        } else {
            format!("{name} provider status")
        },
        message: said,
        warning: status == "warning",
        setup: can_set_up,
    }
}

impl ProviderNotice {
    fn provider(&self, engine: &Engine, key: &str) -> JsonMap<String, Json> {
        if key.is_empty() {
            return JsonMap::new();
        }
        let instance_id = store::with(engine, |s| {
            s.thread_row(key)
                .and_then(|row| row.get("modelSelection"))
                .and_then(Json::as_object)
                .map(|selection| text(selection, "instanceId").to_owned())
        })
        .unwrap_or_default();
        if instance_id.is_empty() {
            return JsonMap::new();
        }
        let config = workspace::environment_config(engine);
        config
            .get("providers")
            .and_then(Json::as_array)
            .and_then(|providers| {
                providers
                    .iter()
                    .filter_map(Json::as_object)
                    .find(|entry| text(entry, "instanceId") == instance_id)
                    .cloned()
            })
            .unwrap_or_default()
    }

    fn publish(&self, engine: &Engine) {
        if !self.active {
            return;
        }
        let key = open_key(engine);
        let entry = self.provider(engine, &key);
        let notice = notice_of(&entry);
        if notice.key.is_empty() || self.dismissed.contains(&notice.key) {
            self.bridge.publish(engine, "providerNotice", Json::Null);
            return;
        }
        self.bridge.publish(
            engine,
            "providerNotice",
            json!({"threadKey": key,
                   "instanceId": text(&entry, "instanceId"),
                   "title": notice.title,
                   "message": notice.message,
                   "warning": notice.warning,
                   "setup": notice.setup}),
        );
    }
}

impl Controller for ProviderNotice {
    fn new(init: Init<'_, Self>) -> Self {
        ProviderNotice {
            bridge: init.bridge,
            me: init.me,
            active: false,
            dismissed: HashSet::new(),
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let me = self.me.clone();
        self.bridge.watch(engine, "route", move |e, _| {
            later(e, &me, |c, e| c.publish(e));
        });
        let me = self.me.clone();
        workspace::on_config_changed(engine, move |e| later(e, &me, |c, e| c.publish(e)));
        let me = self.me.clone();
        store::on_changed(engine, move |e| later(e, &me, |c, e| c.publish(e)));
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, _payload: &Json) -> bool {
        if !self.active {
            return false;
        }
        match action {
            "providerNotice.dismiss" => {
                let notice = notice_of(&self.provider(engine, &open_key(engine)));
                if !notice.key.is_empty() {
                    self.dismissed.insert(notice.key);
                }
                self.publish(engine);
                true
            }
            "providerNotice.setup" => {
                crate::controller::with::<Navigation, _>(engine, |n, engine| {
                    n.open(engine, Route::Settings(PROVIDERS_SECTION.to_owned()));
                });
                true
            }
            _ => false,
        }
    }
}
