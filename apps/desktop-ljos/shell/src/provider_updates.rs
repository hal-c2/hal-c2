//! What the desktop says about provider updates, from the providers
//! the MC reports (`config.providers`): the launch offer, its
//! progress, the sidebar's notice, and the per-environment rows of an
//! offer that spans several environments. Pure, so
//! [`crate::controllers::provider_update_notice`] only wires it to the
//! MC and the toasts; ported from desktop-qt's ProviderUpdates (itself
//! from upstream's ProviderUpdateLaunchNotification.logic.ts).

use std::collections::{HashMap, HashSet};

use chrono::{DateTime, SecondsFormat, TimeDelta, Utc};

use crate::json::Json;

/// How long a success shows (PROVIDER_UPDATE_SUCCESS_VISIBLE_MS).
const SUCCESS_MS: i64 = 3000;

/// packages/contracts PROVIDER_DISPLAY_NAMES.
pub fn driver_name(driver: &str) -> &str {
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

/// "0.51.0" as "v0.51.0".
pub fn version(value: &str) -> String {
    if value.starts_with('v') {
        value.to_owned()
    } else {
        format!("v{value}")
    }
}

/// A string by dotted path ("versionAdvisory.latestVersion").
pub fn field<'a>(object: &'a Json, path: &str) -> &'a str {
    path.split('.')
        .try_fold(object, |value, part| value.get(part))
        .and_then(Json::as_str)
        .unwrap_or_default()
}

fn driver(provider: &Json) -> &str {
    provider["driver"].as_str().unwrap_or_default()
}

/// updateState.status: queued, running, succeeded, failed, unchanged, or "".
pub fn status(provider: &Json) -> &str {
    field(provider, "updateState.status")
}

/// Queued or running.
pub fn active(provider: &Json) -> bool {
    matches!(status(provider), "queued" | "running")
}

fn updatable(provider: &Json) -> bool {
    let advisory = &provider["versionAdvisory"];
    advisory["canUpdate"].as_bool().unwrap_or(false)
        && !advisory["updateCommand"]
            .as_str()
            .unwrap_or_default()
            .is_empty()
}

/// Enabled, behind a latest release this app can use.
pub fn candidate(provider: &Json) -> bool {
    let compatibility = field(provider, "compatibilityAdvisory.latestVersionStatus");
    provider["enabled"].as_bool().unwrap_or(false)
        && compatibility != "broken"
        && compatibility != "unsupported"
        && field(provider, "versionAdvisory.status") == "behind_latest"
        && !field(provider, "versionAdvisory.latestVersion").is_empty()
}

/// One provider per driver, in the order drivers first appear: its
/// default instance (named after the driver), else the one checked last.
pub fn by_driver(providers: &[Json]) -> Vec<Json> {
    let mut chosen: HashMap<&str, &Json> = HashMap::new();
    let mut order: Vec<&str> = Vec::new();
    for provider in providers {
        let name = driver(provider);
        let Some(current) = chosen.get(name).copied() else {
            chosen.insert(name, provider);
            order.push(name);
            continue;
        };
        if provider["instanceId"].as_str() == Some(name)
            || (current["instanceId"].as_str() != Some(name)
                && provider["checkedAt"].as_str() >= current["checkedAt"].as_str())
        {
            chosen.insert(name, provider);
        }
    }
    order.iter().map(|name| chosen[name].clone()).collect()
}

/// The outdated providers, one per driver.
pub fn candidates(providers: &[Json]) -> Vec<Json> {
    let found: Vec<Json> = providers
        .iter()
        .filter(|provider| candidate(provider))
        .cloned()
        .collect();
    by_driver(&found)
}

/// Updated in one click: not already updating, and every outdated
/// instance of its driver updates here with the same command.
pub fn one_click(provider: &Json, providers: &[Json]) -> bool {
    if active(provider) || !updatable(provider) {
        return false;
    }
    let mut commands = HashSet::new();
    for other in providers {
        if driver(other) != driver(provider) || !candidate(other) {
            continue;
        }
        if !updatable(other) {
            return false;
        }
        commands.insert(field(other, "versionAdvisory.updateCommand"));
    }
    commands.len() == 1
}

/// The versions on offer, "codex:0.51.0|claudeAgent:2.1.0" sorted;
/// empty for none.
pub fn key(candidates: &[Json]) -> String {
    let mut parts: Vec<String> = by_driver(candidates)
        .iter()
        .map(|provider| {
            format!(
                "{}:{}",
                driver(provider),
                field(provider, "versionAdvisory.latestVersion")
            )
        })
        .collect();
    parts.sort();
    parts.join("|")
}

/// "Codex", "Codex and Claude", "Codex, Claude, and Cursor".
pub fn list(providers: &[Json]) -> String {
    let names: Vec<&str> = providers
        .iter()
        .map(|provider| driver_name(driver(provider)))
        .collect();
    if names.len() <= 2 {
        return names.join(" and ");
    }
    format!(
        "{}, and {}",
        names[..names.len() - 1].join(", "),
        names[names.len() - 1]
    )
}

/// The newest checkedAt of `providers`; empty when none says.
pub fn latest_checked_at(providers: &[Json]) -> String {
    providers
        .iter()
        .map(|provider| provider["checkedAt"].as_str().unwrap_or_default())
        .max()
        .unwrap_or_default()
        .to_owned()
}

/// A toast's reading of an update.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct View {
    /// initial, running, failed, unchanged, succeeded.
    pub phase: String,
    /// warning, loading, error, success.
    pub kind: String,
    pub title: String,
    pub description: String,
}

impl View {
    pub fn terminal(&self) -> bool {
        matches!(self.phase.as_str(), "succeeded" | "failed" | "unchanged")
    }
}

fn view(phase: &str, kind: &str, title: String, description: String) -> View {
    View {
        phase: phase.into(),
        kind: kind.into(),
        title,
        description,
    }
}

/// The offer: "Update Available: Codex v0.51.0", and whether it updates here.
pub fn offer(candidates: &[Json], one_click: bool) -> View {
    let title = if candidates.len() == 1 {
        format!(
            "Update Available: {} {}",
            driver_name(driver(&candidates[0])),
            version(field(&candidates[0], "versionAdvisory.latestVersion"))
        )
    } else {
        format!("Updates Available: {} providers", candidates.len())
    };
    view(
        "initial",
        "warning",
        title,
        if one_click {
            "Install the update now or review provider settings.".into()
        } else {
            format!(
                "{} can be updated from provider settings.",
                list(candidates)
            )
        },
    )
}

/// An update of `count` providers under way.
pub fn running(count: usize) -> View {
    view(
        "running",
        "loading",
        if count == 1 {
            "Updating provider".into()
        } else {
            "Updating providers".into()
        },
        "Running provider update command.".into(),
    )
}

/// An update the MC refused outright.
pub fn rejected(count: usize, message: &str) -> View {
    view(
        "failed",
        "error",
        if count == 1 {
            "Provider update failed".into()
        } else {
            "Provider updates failed".into()
        },
        message.to_owned(),
    )
}

fn failed_description(failed: &[Json]) -> String {
    let message = if failed.len() == 1 {
        field(&failed[0], "updateState.message")
    } else {
        ""
    };
    if !message.is_empty() {
        message.to_owned()
    } else {
        format!(
            "{} failed to update. Check provider settings for details.",
            list(failed)
        )
    }
}

fn updated_description(count: usize) -> String {
    if count == 1 {
        "New sessions will use the updated provider.".into()
    } else {
        "New sessions will use the updated providers.".into()
    }
}

/// How the update of `count` providers stands from their snapshots:
/// failed, then unchanged, then running until every one reports it
/// succeeded.
pub fn progress(snapshots: &[Json], count: usize) -> View {
    let providers = by_driver(snapshots);
    let failed: Vec<Json> = providers
        .iter()
        .filter(|p| status(p) == "failed")
        .cloned()
        .collect();
    let unchanged: Vec<Json> = providers
        .iter()
        .filter(|p| status(p) == "unchanged")
        .cloned()
        .collect();
    if !failed.is_empty() {
        return view(
            "failed",
            "error",
            if failed.len() == 1 {
                "Provider update failed".into()
            } else {
                "Provider updates failed".into()
            },
            failed_description(&failed),
        );
    }
    if !unchanged.is_empty() {
        return view(
            "unchanged",
            "warning",
            if unchanged.len() == 1 {
                "Provider still needs an update".into()
            } else {
                "Providers still need updates".into()
            },
            format!(
                "{} {} outdated. Check provider settings for details.",
                list(&unchanged),
                if unchanged.len() == 1 {
                    "still appears"
                } else {
                    "still appear"
                }
            ),
        );
    }
    if providers.iter().any(active) {
        return running(count);
    }
    let done = providers.len() >= count
        && providers
            .iter()
            .all(|p| status(p) == "succeeded" || !candidate(p));
    if !done {
        return running(count);
    }
    view(
        "succeeded",
        "success",
        if count == 1 {
            "Provider updated".into()
        } else {
            "Provider updates finished".into()
        },
        updated_description(count),
    )
}

fn severity(provider: &Json) -> i32 {
    match status(provider) {
        "succeeded" => 1,
        "queued" | "running" => 2,
        "unchanged" => 3,
        "failed" => 4,
        _ => 0,
    }
}

/// One snapshot per driver of an update across instances, the worst of
/// how each went: failed, then unchanged, then running, then succeeded.
pub fn worst_by_driver(snapshots: &[Json]) -> Vec<Json> {
    let mut worst: HashMap<&str, &Json> = HashMap::new();
    let mut order: Vec<&str> = Vec::new();
    for snapshot in snapshots {
        let name = driver(snapshot);
        if !worst.contains_key(name) {
            order.push(name);
        }
        if !worst.contains_key(name) || severity(snapshot) > severity(worst[name]) {
            worst.insert(name, snapshot);
        }
    }
    order.iter().map(|name| worst[name].clone()).collect()
}

fn finished_at(provider: &Json) -> &str {
    field(provider, "updateState.finishedAt")
}

/// "codex:<finishedAt>:<message>" of each, sorted.
fn terminal_key(prefix: &str, providers: &[Json]) -> String {
    let mut parts: Vec<String> = providers
        .iter()
        .map(|provider| {
            let finished = finished_at(provider);
            format!(
                "{}:{}:{}",
                driver(provider),
                if finished.is_empty() {
                    "pending"
                } else {
                    finished
                },
                field(provider, "updateState.message")
            )
        })
        .collect();
    parts.sort();
    format!("{prefix}:{}", parts.join("|"))
}

fn latest_finished_at(providers: &[Json]) -> String {
    providers
        .iter()
        .map(finished_at)
        .max()
        .unwrap_or_default()
        .to_owned()
}

/// The sidebar's notice of a provider update: what runs, then the
/// latest of what failed, stayed outdated or succeeded.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Notice {
    /// Changes with the providers' update states, so a dismissed one
    /// returns only once they change.
    pub key: String,
    /// loading, error, warning, success.
    pub tone: String,
    pub title: String,
    pub description: String,
    pub dismissible: bool,
    /// A success goes away by itself after this long.
    pub dismiss_after_ms: i64,
}

/// Only updates that finished at or after `visible_after` (an ISO time)
/// are announced; every one when it is empty. A notice whose key is in
/// `dismissed` gives way to the next.
pub fn notice(all: &[Json], visible_after: &str, dismissed: &HashSet<String>) -> Option<Notice> {
    let providers = by_driver(all);
    let running: Vec<Json> = providers.iter().filter(|p| active(p)).cloned().collect();
    if !running.is_empty() {
        let mut parts: Vec<String> = running
            .iter()
            .map(|p| format!("{}:{}", driver(p), status(p)))
            .collect();
        parts.sort();
        return Some(Notice {
            key: format!("loading:{}", parts.join("|")),
            tone: "loading".into(),
            title: if running.len() == 1 {
                format!("Updating {}", driver_name(driver(&running[0])))
            } else {
                format!("Updating {} providers", running.len())
            },
            description: if running.len() == 1 {
                format!("{} update in progress.", list(&running))
            } else {
                format!("{} updates are in progress.", list(&running))
            },
            dismissible: false,
            dismiss_after_ms: 0,
        });
    }

    let (mut failed, mut unchanged, mut succeeded) = (Vec::new(), Vec::new(), Vec::new());
    for provider in &providers {
        let state = status(provider);
        if !visible_after.is_empty()
            && (finished_at(provider).is_empty() || finished_at(provider) < visible_after)
        {
            continue;
        }
        match state {
            "failed" => failed.push(provider.clone()),
            "unchanged" => unchanged.push(provider.clone()),
            "succeeded" => succeeded.push(provider.clone()),
            _ => {}
        }
    }
    let mut ranked: Vec<(Notice, String)> = Vec::new();
    if !failed.is_empty() {
        let latest = field(&failed[0], "versionAdvisory.latestVersion");
        let name = driver_name(driver(&failed[0]));
        ranked.push((
            Notice {
                key: terminal_key("failed", &failed),
                tone: "error".into(),
                title: if failed.len() > 1 {
                    format!("{} provider updates failed", failed.len())
                } else if !latest.is_empty() {
                    format!("{name} {} update failed", version(latest))
                } else {
                    format!("{name} update failed")
                },
                description: failed_description(&failed),
                dismissible: true,
                dismiss_after_ms: 0,
            },
            latest_finished_at(&failed),
        ));
    }
    if !unchanged.is_empty() {
        ranked.push((
            Notice {
                key: terminal_key("unchanged", &unchanged),
                tone: "warning".into(),
                title: if unchanged.len() == 1 {
                    format!(
                        "{} still needs an update",
                        driver_name(driver(&unchanged[0]))
                    )
                } else {
                    format!("{} providers still need updates", unchanged.len())
                },
                description: format!(
                    "{} {} outdated. Review provider settings for details.",
                    list(&unchanged),
                    if unchanged.len() == 1 {
                        "still appears"
                    } else {
                        "still appear"
                    }
                ),
                dismissible: true,
                dismiss_after_ms: 0,
            },
            latest_finished_at(&unchanged),
        ));
    }
    if !succeeded.is_empty() {
        let first = &succeeded[0];
        let name = driver_name(driver(first));
        let current = first["version"].as_str().unwrap_or_default();
        ranked.push((
            Notice {
                key: terminal_key("succeeded", &succeeded),
                tone: "success".into(),
                title: if succeeded.len() > 1 {
                    format!("{} providers updated", succeeded.len())
                } else if !current.is_empty() {
                    format!("{name} updated: {}", version(current))
                } else {
                    format!("{name} updated")
                },
                description: updated_description(succeeded.len()),
                dismissible: false,
                dismiss_after_ms: SUCCESS_MS,
            },
            latest_finished_at(&succeeded),
        ));
    }
    ranked.sort_by(|a, b| b.1.cmp(&a.1));
    ranked
        .into_iter()
        .find(|(notice, _)| !dismissed.contains(&notice.key))
        .map(|(notice, _)| notice)
}

/// One environment of an offer that spans several.
#[derive(Clone)]
pub struct Group {
    pub environment_id: String,
    pub label: String,
    /// Its providers have not arrived yet (its MC still connecting).
    pub settling: bool,
    /// Its outdated providers that update here in one click.
    pub candidates: Vec<Json>,
    pub providers: Vec<Json>,
}

pub fn group(environment_id: &str, label: &str, providers: &[Json], settling: bool) -> Group {
    Group {
        environment_id: environment_id.to_owned(),
        label: label.to_owned(),
        settling,
        candidates: candidates(providers)
            .into_iter()
            .filter(|provider| one_click(provider, providers))
            .collect(),
        providers: providers.to_vec(),
    }
}

/// "env-a=codex:0.51.0|wsl=claudeAgent:2.1.0": the set on offer; empty
/// for none.
pub fn groups_key(groups: &[Group]) -> String {
    let mut parts = Vec::new();
    for group in groups {
        if group.candidates.is_empty() {
            continue;
        }
        let mut providers: Vec<String> = group
            .candidates
            .iter()
            .map(|provider| {
                format!(
                    "{}:{}",
                    driver(provider),
                    field(provider, "versionAdvisory.latestVersion")
                )
            })
            .collect();
        providers.sort();
        parts.push(format!("{}={}", group.environment_id, providers.join(",")));
    }
    parts.sort();
    parts.join("|")
}

/// How one environment's row stands.
pub struct RowStatus {
    /// idle, loading, success, failed, unchanged.
    pub kind: String,
    pub text: String,
}

/// The update of each environment of an offer: running, timed out, or
/// how its answer said it went. Each start is a request with its own
/// version, so an answer to one the user started again is dropped; an
/// answer to the current one, however late, replaces a timeout.
#[derive(Default)]
pub struct Rows {
    rows: HashMap<String, Row>,
}

#[derive(Default)]
struct Row {
    version: i32,
    running: bool,
    deadline: Option<DateTime<Utc>>,
    error: String,
    result: Option<View>,
}

impl Rows {
    /// How long an update may go unanswered (upstream's PENDING_EXPIRY_MS).
    pub const EXPIRY_MS: i64 = 6 * 60 * 1000;

    /// Starts an update on the environment: its request version, none
    /// while one runs there.
    pub fn start(&mut self, environment_id: &str, now: DateTime<Utc>) -> Option<i32> {
        let row = self.rows.entry(environment_id.to_owned()).or_default();
        if row.running {
            return None;
        }
        row.version += 1;
        row.running = true;
        row.deadline = Some(now + TimeDelta::milliseconds(Self::EXPIRY_MS));
        row.error.clear();
        row.result = None;
        Some(row.version)
    }

    /// The answer to request `version`: an error, or the view of its
    /// snapshots; only a terminal view is kept, the live state saying
    /// the rest.
    pub fn settle(
        &mut self,
        environment_id: &str,
        version: i32,
        error: &str,
        result: Option<View>,
    ) {
        let Some(row) = self.rows.get_mut(environment_id) else {
            return;
        };
        if row.version != version {
            return;
        }
        row.running = false;
        row.deadline = None;
        row.error = error.to_owned();
        row.result = None;
        if error.is_empty()
            && let Some(result) = result
            && result.terminal()
        {
            row.result = Some(result);
        }
    }

    /// The environment's row says why it could not start.
    pub fn refuse(&mut self, environment_id: &str, error: &str) {
        let row = self.rows.entry(environment_id.to_owned()).or_default();
        if row.running {
            return;
        }
        row.error = error.to_owned();
        row.result = None;
    }

    /// The updates unanswered for EXPIRY_MS give up; whether any did.
    pub fn expire(&mut self, now: DateTime<Utc>) -> bool {
        let mut any = false;
        for row in self.rows.values_mut() {
            let Some(deadline) = row.deadline else {
                continue;
            };
            if deadline > now {
                continue;
            }
            row.deadline = None;
            row.running = false;
            row.error = "Update timed out — try again.".into();
            any = true;
        }
        any
    }

    pub fn deadline(&self) -> Option<DateTime<Utc>> {
        self.rows.values().filter_map(|row| row.deadline).min()
    }

    pub fn running(&self, environment_id: &str) -> bool {
        self.rows.get(environment_id).is_some_and(|row| row.running)
    }

    /// The row, from its error, its kept result, the live state of its
    /// candidates (finished at or after `visible_after`), then whether
    /// it runs.
    pub fn status(&self, group: &Group, visible_after: &str) -> RowStatus {
        let empty = Row::default();
        let row = self.rows.get(&group.environment_id).unwrap_or(&empty);
        if !row.error.is_empty() {
            return RowStatus {
                kind: "failed".into(),
                text: row.error.clone(),
            };
        }
        if let Some(result) = &row.result {
            if result.phase == "succeeded" {
                return RowStatus {
                    kind: "success".into(),
                    text: "Updated".into(),
                };
            }
            return RowStatus {
                kind: result.phase.clone(),
                text: result.description.clone(),
            };
        }
        // The live state of what the row offers, not of every provider
        // there, so another provider's success does not hide this one's
        // Update.
        if let Some(live) = notice(&group.candidates, visible_after, &HashSet::new()) {
            return match live.tone.as_str() {
                "success" => RowStatus {
                    kind: "success".into(),
                    text: "Updated".into(),
                },
                "error" => RowStatus {
                    kind: "failed".into(),
                    text: live.description,
                },
                "warning" => RowStatus {
                    kind: "unchanged".into(),
                    text: live.description,
                },
                _ => RowStatus {
                    kind: "loading".into(),
                    text: "Updating…".into(),
                },
            };
        }
        if row.running {
            return RowStatus {
                kind: "loading".into(),
                text: "Updating…".into(),
            };
        }
        let names: Vec<&str> = group
            .candidates
            .iter()
            .map(|provider| driver_name(driver(provider)))
            .collect();
        RowStatus {
            kind: "idle".into(),
            text: names.join(", "),
        }
    }

    pub fn clear(&mut self) {
        self.rows.clear();
    }
}

/// What the sidebar shows of the environment's providers: announced
/// once they finished after the providers were first seen, a success
/// going away after its time, a dismissed one gone until its key
/// changes.
#[derive(Default)]
pub struct Sidebar {
    providers: Vec<Json>,
    visible_after: Option<String>,
    dismissed: HashSet<String>,
    notice: Option<Notice>,
    deadline: Option<DateTime<Utc>>,
}

impl Sidebar {
    /// Whether the notice changed.
    pub fn set_providers(&mut self, providers: &[Json], now: DateTime<Utc>) -> bool {
        // Updates that finished before the providers were first seen
        // happened before this app was looking; they are not news.
        if self.visible_after.is_none() && !providers.is_empty() {
            self.visible_after = Some(latest_checked_at(providers));
        }
        self.providers = providers.to_vec();
        self.refresh(now)
    }

    pub fn dismiss(&mut self, now: DateTime<Utc>) -> bool {
        let Some(notice) = &self.notice else {
            return false;
        };
        if !notice.dismissible {
            return false;
        }
        self.dismissed.insert(notice.key.clone());
        self.refresh(now)
    }

    pub fn expire(&mut self, now: DateTime<Utc>) -> bool {
        let (Some(deadline), Some(notice)) = (self.deadline, &self.notice) else {
            return false;
        };
        if deadline > now {
            return false;
        }
        self.dismissed.insert(notice.key.clone());
        self.refresh(now)
    }

    pub fn deadline(&self) -> Option<DateTime<Utc>> {
        self.deadline
    }

    pub fn current(&self) -> &Option<Notice> {
        &self.notice
    }

    fn refresh(&mut self, now: DateTime<Utc>) -> bool {
        let next = notice(
            &self.providers,
            self.visible_after.as_deref().unwrap_or_default(),
            &self.dismissed,
        );
        let same = next.is_some() == self.notice.is_some()
            && next
                .as_ref()
                .zip(self.notice.as_ref())
                .is_none_or(|(next, current)| next.key == current.key);
        if same {
            // Same notice, maybe reworded; its timer keeps running.
            let reworded =
                next.as_ref()
                    .zip(self.notice.as_ref())
                    .is_some_and(|(next, current)| {
                        next.title != current.title || next.description != current.description
                    });
            if next.is_some() {
                self.notice = next;
            }
            return reworded;
        }
        self.notice = next;
        self.deadline = None;
        if let Some(notice) = &self.notice
            && notice.dismiss_after_ms > 0
        {
            self.deadline = Some(now + TimeDelta::milliseconds(notice.dismiss_after_ms));
        }
        true
    }
}

/// The ISO time the MC's timestamps compare with.
pub fn iso(time: DateTime<Utc>) -> String {
    time.to_rfc3339_opts(SecondsFormat::Millis, true)
}
