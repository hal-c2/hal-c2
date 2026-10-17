//! `providerUpdateNotice`, desktop-qt's ProviderUpdateNotice: the toast that
//! offers provider updates. The enabled providers of this machine's
//! environment that are behind their latest release, one per driver, are
//! offered in one "Update Available" toast. Update runs `server.updateProvider`
//! for each one the MC can update itself and reports how it went; Settings
//! opens the Providers section. Closing the toast dismisses that set of
//! versions for good (this device's `dismissedProviderUpdateNotificationKeys`);
//! a set is offered once per run either way. One per process.
//!
//! Publishes nothing and handles no actions.

use std::cell::RefCell;
use std::collections::{BTreeMap, HashSet};
use std::rc::Rc;

use ljos::prelude::Engine;
use serde_json::json;

use crate::controller::{self, Controller, Init, Me};
use crate::controllers::navigation::{Navigation, PROVIDERS_SECTION, Route};
use crate::controllers::settings::Settings;
use crate::controllers::toasts::{Action, Toasts};
use crate::json::Json;
use crate::mc::Mc;

const DISMISSED: &str = "dismissedProviderUpdateNotificationKeys";
/// How long "Provider updated" stays (PROVIDER_UPDATE_SUCCESS_VISIBLE_MS).
const SUCCESS_MS: i64 = 3000;

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

fn version(value: &str) -> String {
    if value.starts_with('v') {
        value.to_owned()
    } else {
        format!("v{value}")
    }
}

/// The string at the dotted `path` of `provider`.
fn text<'a>(provider: &'a Json, path: &str) -> &'a str {
    path.split('.')
        .try_fold(provider, |value, part| value.get(part))
        .and_then(Json::as_str)
        .unwrap_or_default()
}

fn update_status(provider: &Json) -> &str {
    text(provider, "updateState.status")
}

fn updating(provider: &Json) -> bool {
    matches!(update_status(provider), "queued" | "running")
}

/// Whether a provider is offered an update at launch.
fn candidate(provider: &Json) -> bool {
    let compatibility = text(provider, "compatibilityAdvisory.latestVersionStatus");
    provider["enabled"].as_bool().unwrap_or(false)
        && compatibility != "broken"
        && compatibility != "unsupported"
        && text(provider, "versionAdvisory.status") == "behind_latest"
        && !text(provider, "versionAdvisory.latestVersion").is_empty()
}

fn updatable(provider: &Json) -> bool {
    let advisory = &provider["versionAdvisory"];
    advisory["canUpdate"].as_bool().unwrap_or(false)
        && !advisory["updateCommand"]
            .as_str()
            .unwrap_or_default()
            .is_empty()
}

/// One provider per driver: its default instance (named after the driver),
/// else the one checked last.
fn by_driver(providers: &[Json]) -> Vec<Json> {
    let mut chosen: BTreeMap<&str, &Json> = BTreeMap::new();
    let mut order: Vec<&str> = Vec::new();
    for provider in providers {
        let driver = text(provider, "driver");
        let Some(current) = chosen.get(driver).copied() else {
            chosen.insert(driver, provider);
            order.push(driver);
            continue;
        };
        if text(provider, "instanceId") == driver
            || (text(current, "instanceId") != driver
                && text(provider, "checkedAt") >= text(current, "checkedAt"))
        {
            chosen.insert(driver, provider);
        }
    }
    order.iter().map(|driver| chosen[driver].clone()).collect()
}

fn candidates(providers: &[Json]) -> Vec<Json> {
    let found: Vec<Json> = providers.iter().filter(|p| candidate(p)).cloned().collect();
    by_driver(&found)
}

/// canOneClickUpdateProviderCandidate: not already updating, and every
/// outdated instance of its driver updates with the same command.
fn one_click(provider: &Json, providers: &[Json]) -> bool {
    if updating(provider) || !updatable(provider) {
        return false;
    }
    let driver = text(provider, "driver");
    let mut commands = HashSet::new();
    for other in providers {
        if text(other, "driver") != driver || !candidate(other) {
            continue;
        }
        if !updatable(other) {
            return false;
        }
        commands.insert(text(other, "versionAdvisory.updateCommand"));
    }
    commands.len() == 1
}

/// "Codex", "Codex and Claude", "Codex, Claude, and Cursor".
fn list(providers: &[Json]) -> String {
    let names: Vec<&str> = providers
        .iter()
        .map(|provider| driver_name(text(provider, "driver")))
        .collect();
    match names.as_slice() {
        [] => String::new(),
        [one] => (*one).to_owned(),
        [first, second] => format!("{first} and {second}"),
        [rest @ .., last] => format!("{}, and {last}", rest.join(", ")),
    }
}

/// The update the user started: which instances, until it is reported.
struct Update {
    instance_ids: HashSet<String>,
    count: usize,
}

/// The sequential `server.updateProvider` calls of one update.
struct Run {
    providers: Vec<Json>,
    next: usize,
    snapshots: Vec<Json>,
}

pub struct ProviderUpdateNotice {
    me: Me<ProviderUpdateNotice>,
    mc: Rc<dyn Mc>,
    active: bool,
    hooked: bool,
    /// The version sets offered this run.
    seen: HashSet<String>,
    /// The prompt on screen and the versions it offers.
    prompt: Option<(String, String)>,
    update: Option<Update>,
}

impl Controller for ProviderUpdateNotice {
    fn new(init: Init<'_, Self>) -> Self {
        ProviderUpdateNotice {
            me: init.me,
            mc: init.mc,
            active: false,
            hooked: false,
            seen: HashSet::new(),
            prompt: None,
            update: None,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if std::mem::replace(&mut self.active, true) {
            return;
        }
        let me = self.me.clone();
        Settings::of(engine).on_config_changed(move |engine| {
            me.run(engine, |c, engine| c.evaluate(engine));
        });
        self.evaluate(engine);
    }

    fn attach(&mut self, engine: &Engine, _window: &crate::controller::Window) {
        self.evaluate(engine);
    }
}

fn providers_of(engine: &Engine) -> Vec<Json> {
    Settings::of(engine)
        .config()
        .get("providers")
        .and_then(Json::as_array)
        .cloned()
        .unwrap_or_default()
}

fn dismissed_keys(engine: &Engine) -> Vec<String> {
    Settings::of(engine)
        .device_value(DISMISSED)
        .and_then(|keys| {
            keys.as_array().map(|keys| {
                keys.iter()
                    .filter_map(Json::as_str)
                    .map(str::to_owned)
                    .collect()
            })
        })
        .unwrap_or_default()
}

impl ProviderUpdateNotice {
    /// Follows what the MC says of the providers: the update the user
    /// started, or else whether to offer one.
    fn evaluate(&mut self, engine: &Engine) {
        if !self.active {
            return;
        }
        let providers = providers_of(engine);

        // An update the user started reports once the MC says how it went.
        if let Some(update) = &self.update {
            let followed: Vec<Json> = providers
                .iter()
                .filter(|p| update.instance_ids.contains(text(p, "instanceId")))
                .cloned()
                .collect();
            if self.report(engine, &followed) {
                self.update = None;
            }
            return;
        }

        let outdated = candidates(&providers);
        let mut parts: Vec<String> = outdated
            .iter()
            .map(|p| {
                format!(
                    "{}:{}",
                    text(p, "driver"),
                    text(p, "versionAdvisory.latestVersion")
                )
            })
            .collect();
        parts.sort();
        let key = parts.join("|");

        // Other versions than the prompt offers: it no longer says what is true.
        if let Some((id, shown)) = &self.prompt
            && *shown != key
        {
            let id = id.clone();
            self.prompt = None;
            controller::with::<Toasts, _>(engine, |toasts, engine| toasts.dismiss(engine, &id));
        }
        if key.is_empty()
            || self.prompt.is_some()
            || self.seen.contains(&key)
            || dismissed_keys(engine).contains(&key)
        {
            return;
        }
        self.seen.insert(key.clone());

        let one_click_providers: Vec<Json> = outdated
            .iter()
            .filter(|p| one_click(p, &providers))
            .cloned()
            .collect();
        let title = if let [only] = outdated.as_slice() {
            format!(
                "Update Available: {} {}",
                driver_name(text(only, "driver")),
                version(text(only, "versionAdvisory.latestVersion"))
            )
        } else {
            format!("Updates Available: {} providers", outdated.len())
        };
        let description = if one_click_providers.is_empty() {
            format!("{} can be updated from provider settings.", list(&outdated))
        } else {
            "Install the update now or review provider settings.".to_owned()
        };
        let mut actions = Vec::new();
        if !one_click_providers.is_empty() {
            let me = self.me.clone();
            actions.push(Action::new("Update", move |engine| {
                let chosen = one_click_providers.clone();
                me.run(engine, |c, engine| c.run_updates(engine, chosen));
            }));
        }
        actions.push(self.settings_action());

        self.hook(engine);
        let id = controller::with::<Toasts, _>(engine, |toasts, engine| {
            toasts.show_actions(engine, "warning", &title, &description, actions, 0)
        });
        if let Some(id) = id {
            self.prompt = Some((id, key));
        }
    }

    /// Closing the prompt by hand dismisses the versions it offered for good.
    fn hook(&mut self, engine: &Engine) {
        if std::mem::replace(&mut self.hooked, true) {
            return;
        }
        let me = self.me.clone();
        controller::with::<Toasts, _>(engine, |toasts, _| {
            toasts.on_closed_by_user(move |engine, id| {
                let id = id.to_owned();
                me.run(engine, |c, engine| {
                    let Some((shown, key)) = c.prompt.clone() else {
                        return;
                    };
                    if shown != id {
                        return;
                    }
                    c.prompt = None;
                    let mut dismissed = dismissed_keys(engine);
                    if !dismissed.contains(&key) {
                        dismissed.push(key);
                    }
                    Settings::of(engine).write_device(engine, DISMISSED, json!(dismissed));
                });
            });
        });
    }

    fn settings_action(&self) -> Action {
        let me = self.me.clone();
        Action::new("Settings", move |engine| {
            me.run(engine, |c, engine| c.open_settings(engine));
        })
    }

    fn open_settings(&mut self, engine: &Engine) {
        self.prompt = None;
        controller::with::<Navigation, _>(engine, |navigation, engine| {
            navigation.open(engine, Route::Settings(PROVIDERS_SECTION.into()));
        });
    }

    fn toast(
        &self,
        engine: &Engine,
        kind: &str,
        title: &str,
        description: &str,
        actions: Vec<Action>,
        timeout_ms: i64,
    ) {
        controller::with::<Toasts, _>(engine, |toasts, engine| {
            toasts.show_actions(engine, kind, title, description, actions, timeout_ms);
        });
    }

    /// Updates `providers` one after another; the first refusal ends it.
    fn run_updates(&mut self, engine: &Engine, providers: Vec<Json>) {
        self.prompt = None;
        self.update = Some(Update {
            instance_ids: providers
                .iter()
                .map(|p| text(p, "instanceId").to_owned())
                .collect(),
            count: providers.len(),
        });
        let run = Rc::new(RefCell::new(Run {
            providers,
            next: 0,
            snapshots: Vec::new(),
        }));
        self.step(engine, run);
    }

    fn step(&mut self, engine: &Engine, run: Rc<RefCell<Run>>) {
        if self.update.is_none() {
            return;
        }
        let provider = {
            let mut run = run.borrow_mut();
            if run.next >= run.providers.len() {
                // The answers' snapshots of the updated instances; a later
                // `config.providers` reports it if these do not settle it.
                let snapshots = run.snapshots.clone();
                drop(run);
                if self.report(engine, &snapshots) {
                    self.update = None;
                }
                return;
            }
            run.next += 1;
            run.providers[run.next - 1].clone()
        };
        let request = json!({
            "provider": provider["driver"],
            "instanceId": provider["instanceId"],
        });
        let me = self.me.clone();
        self.mc.call(
            &self.mc.environment(),
            "server.updateProvider",
            request,
            Box::new(move |engine, result| {
                crate::bridge::Bridge::of(engine).defer(engine, move |engine| {
                    me.run(engine, |c, engine| c.answered(engine, run, result));
                });
            }),
        );
    }

    fn answered(
        &mut self,
        engine: &Engine,
        run: Rc<RefCell<Run>>,
        result: Result<Json, crate::mc::McError>,
    ) {
        let Some(update) = &self.update else { return };
        match result {
            Err(error) => {
                let count = update.count;
                self.update = None;
                let message = if error.message.is_empty() {
                    "Provider update failed."
                } else {
                    &error.message
                };
                self.toast(
                    engine,
                    "error",
                    if count == 1 {
                        "Provider update failed"
                    } else {
                        "Provider updates failed"
                    },
                    message,
                    vec![self.settings_action()],
                    0,
                );
            }
            Ok(result) => {
                for provider in result["providers"].as_array().into_iter().flatten() {
                    if update.instance_ids.contains(text(provider, "instanceId")) {
                        run.borrow_mut().snapshots.push(provider.clone());
                    }
                }
                self.step(engine, run);
            }
        }
    }

    /// getProviderUpdateProgressToastView: failed, then unchanged, then done
    /// once every provider reports it succeeded. Reports once no provider is
    /// still updating; false while one is.
    fn report(&mut self, engine: &Engine, snapshots: &[Json]) -> bool {
        let Some(update) = &self.update else {
            return true;
        };
        let count = update.count;
        let providers = by_driver(snapshots);
        let failed: Vec<Json> = providers
            .iter()
            .filter(|p| update_status(p) == "failed")
            .cloned()
            .collect();
        let unchanged: Vec<Json> = providers
            .iter()
            .filter(|p| update_status(p) == "unchanged")
            .cloned()
            .collect();
        if !failed.is_empty() {
            let message = text(&failed[0], "updateState.message");
            let description = if failed.len() == 1 && !message.is_empty() {
                message.to_owned()
            } else {
                format!(
                    "{} failed to update. Check provider settings for details.",
                    list(&failed)
                )
            };
            self.toast(
                engine,
                "error",
                if failed.len() == 1 {
                    "Provider update failed"
                } else {
                    "Provider updates failed"
                },
                &description,
                vec![self.settings_action()],
                0,
            );
            return true;
        }
        if !unchanged.is_empty() {
            let (title, verb) = if unchanged.len() == 1 {
                ("Provider still needs an update", "still appears")
            } else {
                ("Providers still need updates", "still appear")
            };
            self.toast(
                engine,
                "warning",
                title,
                &format!(
                    "{} {verb} outdated. Check provider settings for details.",
                    list(&unchanged)
                ),
                vec![self.settings_action()],
                0,
            );
            return true;
        }
        if providers.iter().any(updating) {
            return false;
        }
        let done = providers.len() >= count
            && providers
                .iter()
                .all(|p| update_status(p) == "succeeded" || !candidate(p));
        if !done {
            return false;
        }
        let (title, description) = if count == 1 {
            (
                "Provider updated",
                "New sessions will use the updated provider.",
            )
        } else {
            (
                "Provider updates finished",
                "New sessions will use the updated providers.",
            )
        };
        self.toast(
            engine,
            "success",
            title,
            description,
            Vec::new(),
            SUCCESS_MS,
        );
        true
    }
}
