//! What the phone does with an MC's push (the contract is the MC's
//! HalC2.Push), mobile-qt's push/PushInbox: open it, drop it when it
//! is stale, from the future, already shown or not allowed, and say
//! what the system's notifications should become. It is apart from
//! the engine and the controllers, because on Android the push
//! receiver calls it while the app may not be running (the Java
//! receivers reach it through JNI once Ljós has that seam,
//! hal-c2/ljos-ui#616); the app and that receiver share its file,
//! `<data>/push.json`, under one lock.
//!
//! Every call answers with effects, which the platform renders as
//! they are:
//!   {channels: [{id, name, importance}],
//!    alert?: {tag, id, channel, title, body, link, visibility,
//!             publicTitle, publicText},
//!    card?: {id, channel, title, text, lines, subtext, chip?,
//!            action?, dismissAction?, ongoing, promoted, link,
//!            timeoutMs, silent, showWhen, visibility, publicTitle,
//!            publicText},
//!    cancelCard?: true}

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use ring::digest::{SHA256, digest};
use serde_json::{Map, Value as Json, json};

use crate::push_crypto::{Keys, decrypt, generate_keys};

const MINUTE: i64 = 60 * 1000;
/// Older or newer than this against the phone's clock, a message is
/// not news.
const FRESHNESS: i64 = 10 * MINUTE;
/// A running card with no word of its end goes after this.
const ACTIVE_LIFETIME: i64 = 120 * MINUTE;
/// How long a finished thread stays on the card.
const FINISHED_LIFETIME: i64 = 15 * MINUTE;
/// The longest a card stays up, whatever it is told.
const LONGEST_CARD: i64 = 24 * 60 * MINUTE;
/// The alerts shown, by id, so a redelivery shows nothing.
const SEEN: usize = 64;

pub const CARD_ID: i64 = 73001;
pub const ALERT_CHANNEL: &str = "agent-alerts";
pub const ACTIVITY_CHANNEL: &str = "agent-activity";

static FOREGROUND: AtomicBool = AtomicBool::new(false);

/// The app's thread and Android's receiver read and write the one
/// file (PushInbox's `g_lock`).
fn lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

/// Whether the app is on screen, for a receiver in the same process.
pub fn set_foreground(on: bool) {
    FOREGROUND.store(on, Ordering::SeqCst);
}

pub fn foreground() -> bool {
    FOREGROUND.load(Ordering::SeqCst)
}

/// What the phone is like as a message arrives.
#[derive(Clone, Copy, Debug)]
pub struct Device {
    /// Wall clock, ms since the epoch.
    pub now: i64,
    /// The app is on screen: its own views show what an alert would.
    pub foreground: bool,
    /// The system lets HAL-C2 post notifications.
    pub permitted: bool,
    /// Android's API level; 0 off Android.
    pub sdk: i32,
}

/// A string field in `limit` UTF-16 units, as QString counts them:
/// simplified (trimmed, its whitespace runs one space), then cut
/// with an ellipsis.
fn text(object: &Map<String, Json>, key: &str, limit: usize) -> String {
    let value = object.get(key).and_then(Json::as_str).unwrap_or_default();
    let simple = value.split_whitespace().collect::<Vec<_>>().join(" ");
    if simple.encode_utf16().count() <= limit {
        return simple;
    }
    let mut units = 0usize;
    let mut kept = String::new();
    for c in simple.chars() {
        let width = c.len_utf16();
        if units + width > limit.saturating_sub(1) {
            break;
        }
        units += width;
        kept.push(c);
    }
    kept.push('\u{2026}');
    kept
}

fn from_base64_url(value: Option<&Json>) -> Vec<u8> {
    value
        .and_then(Json::as_str)
        .and_then(|text| URL_SAFE_NO_PAD.decode(text).ok())
        .unwrap_or_default()
}

fn base64_url(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

/// A timestamp stored as JSON numbers were in Qt: a double there, an
/// integer here; read either way.
fn at(object: &Map<String, Json>, key: &str) -> i64 {
    object.get(key).and_then(Json::as_f64).unwrap_or_default() as i64
}

fn object_of(value: &Json) -> Map<String, Json> {
    value.as_object().cloned().unwrap_or_default()
}

/// The kept state: empty when there is no file yet, none when a
/// file there is cannot be read or parsed. A change is never saved
/// over a file that could not be read (it may hold the only copy of
/// the subscription keys): mutating calls leave it intact, and
/// `forget`, the user's own reset, is the one recovery that
/// replaces it. (mobile-qt's load mapped both failures to empty and
/// a later save overwrote the file; that is not carried over.)
fn try_load(path: &Path) -> Option<Map<String, Json>> {
    match std::fs::read(path) {
        Ok(bytes) => serde_json::from_slice::<Json>(&bytes)
            .ok()
            .filter(Json::is_object)
            .map(|value| object_of(&value)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Some(Map::new()),
        Err(_) => None,
    }
}

/// For reads alone, where the defaults the C++ read are the answer.
fn load(path: &Path) -> Map<String, Json> {
    try_load(path).unwrap_or_default()
}

/// The keys are in here: the file is the user's alone from its first
/// byte, and whole or the one it replaces (QSaveFile, as the
/// pairing's save). False when it could not be written: keys are
/// handed out only once they are on disk.
fn save(path: &Path, state: &Map<String, Json>) -> bool {
    let done = (|| -> std::io::Result<()> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let bytes = serde_json::to_vec(state).map_err(std::io::Error::other)?;
        let tmp = path.with_extension("json.tmp");
        match std::fs::remove_file(&tmp) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(e),
            _ => {}
        }
        let written = (|| {
            use std::io::Write;
            let mut options = std::fs::OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
            let mut file = options.open(&tmp)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            std::fs::rename(&tmp, path)
        })();
        if written.is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
        written
    })();
    if let Err(error) = &done {
        eprintln!("[push] not saved to {}: {error}", path.display());
    }
    done.is_ok()
}

fn keys_of(state: &Map<String, Json>) -> Keys {
    let keys = state.get("keys").map(object_of).unwrap_or_default();
    Keys {
        private_key: from_base64_url(keys.get("private")),
        public_key: from_base64_url(keys.get("p256dh")),
        auth: from_base64_url(keys.get("auth")),
    }
}

/// A phase of the contract: a row's status label, the live update's
/// chip and the card's action.
struct Phase {
    name: &'static str,
    status: &'static str,
    chip: &'static str,
    action: &'static str,
}

const PHASES: &[Phase] = &[
    Phase {
        name: "starting",
        status: "Connecting",
        chip: "Working",
        action: "Open",
    },
    Phase {
        name: "running",
        status: "Working",
        chip: "Working",
        action: "Open",
    },
    Phase {
        name: "waiting_for_approval",
        status: "Approval",
        chip: "Approve",
        action: "Approve",
    },
    Phase {
        name: "waiting_for_input",
        status: "Input",
        chip: "Answer",
        action: "Answer",
    },
    Phase {
        name: "stale",
        status: "Waiting",
        chip: "Waiting",
        action: "Open",
    },
    Phase {
        name: "completed",
        status: "Done",
        chip: "Done",
        action: "Open",
    },
    Phase {
        name: "failed",
        status: "Failed",
        chip: "Failed",
        action: "Open",
    },
];

fn phase_by_name(name: &str) -> Option<&'static Phase> {
    PHASES.iter().find(|phase| phase.name == name)
}

fn phase_of(activity: &Map<String, Json>) -> Option<&'static Phase> {
    phase_by_name(
        activity
            .get("phase")
            .and_then(Json::as_str)
            .unwrap_or_default(),
    )
}

struct Row {
    status: String,
    title: String,
    project: String,
}

fn rows_of(activity: &Map<String, Json>) -> Vec<Row> {
    activity
        .get("rows")
        .and_then(Json::as_array)
        .map(|rows| {
            rows.iter()
                .map(|value| {
                    let row = object_of(value);
                    Row {
                        status: text(&row, "status", 40),
                        title: text(&row, "title", 120),
                        project: text(&row, "project", 120),
                    }
                })
                .collect()
        })
        .unwrap_or_default()
}

fn summary(activity: &Map<String, Json>, rows: &[Row]) -> String {
    if rows.is_empty() {
        return "Agent activity".into();
    }
    if rows.len() == 1 {
        return rows[0].title.clone();
    }
    let attention = activity
        .get("attentionCount")
        .and_then(Json::as_i64)
        .unwrap_or_default();
    if attention == 1 {
        return "1 needs you".into();
    }
    if attention > 1 {
        return format!("{attention} need you");
    }
    let failed = rows.iter().filter(|row| row.status == "Failed").count();
    if activity
        .get("active")
        .and_then(Json::as_bool)
        .unwrap_or(false)
    {
        if failed > 0 {
            return format!("{failed} failed");
        }
        let active = activity
            .get("activeCount")
            .and_then(Json::as_i64)
            .unwrap_or_default();
        return format!("{active} working");
    }
    if failed > 0 {
        format!("Finished, {failed} failed")
    } else {
        "All finished".into()
    }
}

/// The live update's chip, for work in progress alone.
fn chip(activity: &Map<String, Json>, phase: Option<&Phase>) -> String {
    let Some(phase) = phase else {
        return "Active".into();
    };
    let active = activity
        .get("activeCount")
        .and_then(Json::as_i64)
        .unwrap_or_default();
    if phase.name == "running" && active > 1 {
        return if active > 9 {
            "9+ live".into()
        } else {
            format!("{active} live")
        };
    }
    phase.chip.into()
}

fn alert_effect(alert: &Map<String, Json>) -> Json {
    let id = alert.get("id").and_then(Json::as_str).unwrap_or_default();
    let hashed = digest(&SHA256, id.as_bytes());
    let bytes = hashed.as_ref();
    let number = (u32::from(bytes[0]) << 24
        | u32::from(bytes[1]) << 16
        | u32::from(bytes[2]) << 8
        | u32::from(bytes[3]))
        & 0x7fff_ffff;
    let body: String = alert
        .get("body")
        .and_then(Json::as_str)
        .unwrap_or_default()
        .chars()
        .take(4000)
        .collect();
    json!({
        "tag": "hal-c2-agent-alert",
        "id": number,
        "key": id,
        "channel": ALERT_CHANNEL,
        "title": text(alert, "title", 120),
        "body": body,
        "link": thread_link(alert),
        "visibility": "private",
        "publicTitle": "HAL-C2",
        "publicText": "Agent update",
    })
}

fn cancel_card(effects: &mut Map<String, Json>) {
    effects.insert("cancelCard".into(), json!(true));
}

/// The push inbox over `<data>/push.json`.
pub struct Inbox {
    path: PathBuf,
}

impl Inbox {
    pub fn new(data_dir: &Path) -> Inbox {
        Inbox {
            path: data_dir.join("push.json"),
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// This phone's push keys, made the first time they are asked for.
    pub fn keys(&self) -> Keys {
        let _held = lock().lock().unwrap_or_else(|held| held.into_inner());
        let Some(mut state) = try_load(&self.path) else {
            return Keys::default();
        };
        let keys = keys_of(&state);
        if keys.valid() {
            return keys;
        }
        let keys = generate_keys();
        if !keys.valid() {
            return Keys::default();
        }
        state.insert(
            "keys".into(),
            json!({
                "private": base64_url(&keys.private_key),
                "p256dh": base64_url(&keys.public_key),
                "auth": base64_url(&keys.auth),
            }),
        );
        // Only keys on disk are handed out: an unsaved pair would be
        // registered and then replaced by the next generation.
        if save(&self.path, &state) {
            keys
        } else {
            Keys::default()
        }
    }

    pub fn live_activity(&self) -> bool {
        let _held = lock().lock().unwrap_or_else(|held| held.into_inner());
        load(&self.path)
            .get("liveActivity")
            .and_then(Json::as_bool)
            .unwrap_or(true)
    }

    /// Turning live activity off takes the card down; turning it on
    /// lets the next one show even if the user had dismissed the last.
    pub fn set_live_activity(&self, on: bool) -> Json {
        let _held = lock().lock().unwrap_or_else(|held| held.into_inner());
        if let Some(mut state) = try_load(&self.path) {
            state.insert("liveActivity".into(), json!(on));
            state.insert("dismissed".into(), json!(false));
            save(&self.path, &state);
        }
        let mut effects = object_of(&channels());
        if !on {
            cancel_card(&mut effects);
        }
        Json::Object(effects)
    }

    /// An encrypted message from the distributor. The keys it opens
    /// with and the state it lands in are one transaction: a forget
    /// between the two must not let an old subscription's alert
    /// through, so the lock is held across the decrypt (the C++
    /// dropped it there).
    pub fn receive(&self, body: &[u8], device: &Device) -> Json {
        let _held = lock().lock().unwrap_or_else(|held| held.into_inner());
        let keys = keys_of(&load(&self.path));
        let Some(plain) = decrypt(body, &keys) else {
            return channels();
        };
        let message = serde_json::from_slice::<Json>(&plain)
            .map(|value| object_of(&value))
            .unwrap_or_default();
        self.deliver_locked(&message, device)
    }

    /// A message in the clear: a decrypted one, or the activity the
    /// app works out itself from what it shows, marked `local: true`.
    /// Each is ordered against the last from the same place, since
    /// the MC's clock is not the phone's.
    pub fn deliver(&self, message: &Map<String, Json>, device: &Device) -> Json {
        let _held = lock().lock().unwrap_or_else(|held| held.into_inner());
        self.deliver_locked(message, device)
    }

    fn deliver_locked(&self, message: &Map<String, Json>, device: &Device) -> Json {
        let mut effects = object_of(&channels());
        let sent_at = at(message, "sentAt");
        // Nothing is recorded of a message that is not shown for these
        // reasons, so the same one delivered again once they pass is
        // shown then.
        if sent_at <= 0
            || device.now.saturating_sub(sent_at).unsigned_abs() > FRESHNESS as u64
            || !device.permitted
        {
            return Json::Object(effects);
        }

        let Some(mut state) = try_load(&self.path) else {
            return Json::Object(effects);
        };

        let alert = message.get("alert").map(object_of).unwrap_or_default();
        let id = alert
            .get("id")
            .and_then(Json::as_str)
            .unwrap_or_default()
            .to_owned();
        if !id.is_empty() {
            let mut seen: Vec<Json> = state
                .get("seen")
                .and_then(Json::as_array)
                .cloned()
                .unwrap_or_default();
            if !seen.iter().any(|held| held.as_str() == Some(id.as_str())) {
                // An open app shows the thread itself; the alert
                // counts as seen.
                if !device.foreground {
                    effects.insert("alert".into(), alert_effect(&alert));
                }
                seen.push(json!(id));
                while seen.len() > SEEN {
                    seen.remove(0);
                }
                state.insert("seen".into(), Json::Array(seen));
            }
        }

        let last_update = if message
            .get("local")
            .and_then(Json::as_bool)
            .unwrap_or(false)
        {
            "lastLocalUpdate"
        } else {
            "lastUpdate"
        };
        if let Some(activity) = message.get("activity").filter(|value| value.is_object())
            && sent_at >= at(&state, last_update)
        {
            let activity = object_of(activity);
            state.insert(last_update.into(), json!(sent_at as f64));
            let active = activity
                .get("active")
                .and_then(Json::as_bool)
                .unwrap_or(false);
            let was_active = state
                .get("lastActive")
                .and_then(Json::as_bool)
                .unwrap_or(false);
            state.insert("lastActive".into(), json!(active));
            let expires_at = if activity.contains_key("expiresAt") {
                at(&activity, "expiresAt")
            } else if active {
                sent_at.saturating_add(ACTIVE_LIFETIME)
            } else {
                sent_at
            };
            let remaining = expires_at.saturating_sub(device.now).min(LONGEST_CARD);
            let live = state
                .get("liveActivity")
                .and_then(Json::as_bool)
                .unwrap_or(true);
            if remaining <= 0 || !live {
                cancel_card(&mut effects);
                state.insert("dismissed".into(), json!(false));
            } else {
                // A run that starts again brings back a card the
                // user put away.
                if active && !was_active {
                    state.insert("dismissed".into(), json!(false));
                }
                if !state
                    .get("dismissed")
                    .and_then(Json::as_bool)
                    .unwrap_or(false)
                {
                    effects.insert("card".into(), card(&activity, remaining, device.sdk));
                }
            }
        }
        save(&self.path, &state);
        Json::Object(effects)
    }

    /// The user swiped the card away, or tapped its dismiss action:
    /// it stays away until a run starts again.
    pub fn dismiss(&self) -> Json {
        let _held = lock().lock().unwrap_or_else(|held| held.into_inner());
        if let Some(mut state) = try_load(&self.path) {
            state.insert("dismissed".into(), json!(true));
            save(&self.path, &state);
        }
        let mut effects = object_of(&channels());
        cancel_card(&mut effects);
        Json::Object(effects)
    }

    pub fn dismissed(&self) -> bool {
        let _held = lock().lock().unwrap_or_else(|held| held.into_inner());
        load(&self.path)
            .get("dismissed")
            .and_then(Json::as_bool)
            .unwrap_or(false)
    }

    /// The environment was forgotten: new keys and no endpoint, so
    /// what its MC still pushes cannot be opened, and nothing of
    /// what was shown kept. The user's choices stay.
    pub fn forget(&self) -> Json {
        let _held = lock().lock().unwrap_or_else(|held| held.into_inner());
        let state = load(&self.path);
        let mut kept = Map::new();
        for key in ["distributor", "liveActivity", "quietHours"] {
            if let Some(value) = state.get(key) {
                kept.insert(key.into(), value.clone());
            }
        }
        save(&self.path, &kept);
        let mut effects = object_of(&channels());
        cancel_card(&mut effects);
        Json::Object(effects)
    }

    /// The app's own choices kept beside the inbox's: the
    /// distributor, the endpoint it gave (which Android's receiver
    /// writes) and quiet hours.
    pub fn value(&self, key: &str) -> Json {
        let _held = lock().lock().unwrap_or_else(|held| held.into_inner());
        load(&self.path).get(key).cloned().unwrap_or(Json::Null)
    }

    pub fn set_value(&self, key: &str, value: Json) {
        let _held = lock().lock().unwrap_or_else(|held| held.into_inner());
        let Some(mut state) = try_load(&self.path) else {
            return;
        };
        if state.get(key) == Some(&value) {
            return;
        }
        // As QJsonObject::insert of an undefined value: it goes.
        if value.is_null() {
            state.remove(key);
        } else {
            state.insert(key.into(), value);
        }
        save(&self.path, &state);
    }
}

/// One thread of an activity message: its phase as the contract
/// names it (starting, running, waiting_for_approval,
/// waiting_for_input, stale, completed, failed) and when it last
/// changed, or finished.
#[derive(Clone, Debug)]
pub struct ActivityRow {
    pub phase: String,
    pub title: String,
    pub project: String,
    pub environment_id: String,
    pub thread_id: String,
    pub at: i64,
}

/// The activity of a message for these threads as of `now`, as the
/// MC builds it: those that need the user first, then failed,
/// working and done ones, newest first in each, five at most;
/// finished ones only for 15 minutes.
pub fn activity(rows: Vec<ActivityRow>, now: i64) -> Json {
    fn group(phase: &str) -> u8 {
        match phase {
            "waiting_for_approval" | "waiting_for_input" => 0,
            "failed" => 1,
            "completed" => 3,
            _ => 2,
        }
    }
    let finished = |row: &ActivityRow| group(&row.phase) == 3 || row.phase == "failed";
    let mut rows: Vec<ActivityRow> = rows
        .into_iter()
        .filter(|row| {
            phase_by_name(&row.phase).is_some()
                && !(finished(row) && row.at < now - FINISHED_LIFETIME)
        })
        .collect();
    rows.sort_by(|a, b| {
        group(&a.phase)
            .cmp(&group(&b.phase))
            .then_with(|| b.at.cmp(&a.at))
    });
    let mut active = 0i64;
    let mut attention = 0i64;
    let mut last_finish = 0i64;
    let mut listed = Vec::new();
    for row in &rows {
        if finished(row) {
            last_finish = last_finish.max(row.at);
        } else {
            active += 1;
        }
        if group(&row.phase) == 0 {
            attention += 1;
        }
        if listed.len() < 5 {
            listed.push(json!({
                "status": phase_by_name(&row.phase).map(|phase| phase.status).unwrap_or_default(),
                "title": row.title,
                "project": row.project,
                "environmentId": row.environment_id,
                "threadId": row.thread_id,
            }));
        }
    }
    let expires_at = if active > 0 {
        now + ACTIVE_LIFETIME
    } else if rows.is_empty() {
        now
    } else {
        last_finish + FINISHED_LIFETIME
    };
    let mut result = Map::new();
    result.insert("active".into(), json!(active > 0));
    result.insert("activeCount".into(), json!(active));
    result.insert("attentionCount".into(), json!(attention));
    result.insert("rows".into(), Json::Array(listed));
    result.insert("expiresAt".into(), json!(expires_at as f64));
    if let Some(first) = rows.first() {
        result.insert("phase".into(), json!(first.phase));
        result.insert("environmentId".into(), json!(first.environment_id));
        result.insert("threadId".into(), json!(first.thread_id));
        let link = thread_link(&result);
        result.insert("link".into(), json!(link));
    }
    Json::Object(result)
}

/// The two notification channels, so they can be silenced apart.
pub fn channels() -> Json {
    json!({
        "channels": [
            {"id": ALERT_CHANNEL, "name": "Agent alerts", "importance": "high"},
            {"id": ACTIVITY_CHANNEL, "name": "Ongoing agent activity", "importance": "low"},
        ]
    })
}

/// The card for an activity, as of `now` with `remaining_ms` to run.
pub fn card(activity: &Map<String, Json>, remaining_ms: i64, sdk: i32) -> Json {
    let active = activity
        .get("active")
        .and_then(Json::as_bool)
        .unwrap_or(false);
    let phase = phase_of(activity);
    let rows = rows_of(activity);
    let mut lines: Vec<String> = Vec::new();
    let mut subtext = String::new();
    if rows.len() == 1 {
        let row = &rows[0];
        lines.push(if row.project.is_empty() {
            row.status.clone()
        } else {
            format!("{} · {}", row.status, row.project)
        });
    } else if !rows.is_empty() {
        let one_project = rows.iter().all(|row| row.project == rows[0].project);
        for row in &rows {
            let mut line = format!("{} {}", row.status, row.title);
            if !one_project && !row.project.is_empty() {
                line.push_str(&format!(" · {}", row.project));
            }
            lines.push(line);
        }
        let mut parts: Vec<String> = Vec::new();
        if one_project && !rows[0].project.is_empty() {
            parts.push(rows[0].project.clone());
        }
        parts.push(if active {
            let count = activity
                .get("activeCount")
                .and_then(Json::as_i64)
                .unwrap_or_default();
            format!("{count} active")
        } else {
            format!("{} threads", rows.len())
        });
        subtext = parts.join(" · ");
    }
    let mut card = Map::new();
    card.insert("id".into(), json!(CARD_ID));
    card.insert("channel".into(), json!(ACTIVITY_CHANNEL));
    card.insert("title".into(), json!(summary(activity, &rows)));
    card.insert(
        "text".into(),
        json!(lines.first().cloned().unwrap_or_default()),
    );
    card.insert("lines".into(), json!(lines));
    card.insert("subtext".into(), json!(subtext));
    card.insert("ongoing".into(), json!(active));
    // Android 16 lifts an ongoing card to a live update in the
    // status bar.
    card.insert("promoted".into(), json!(active && sdk >= 36));
    card.insert("link".into(), json!(thread_link(activity)));
    card.insert("timeoutMs".into(), json!(remaining_ms as f64));
    card.insert("silent".into(), json!(true));
    card.insert("showWhen".into(), json!(false));
    card.insert("visibility".into(), json!("private"));
    card.insert("publicTitle".into(), json!("HAL-C2"));
    card.insert("publicText".into(), json!("Agent activity"));
    // Finished work has no chip and no buttons: the card is tapped
    // or let go.
    if active {
        card.insert("chip".into(), json!(chip(activity, phase)));
        card.insert(
            "action".into(),
            json!(phase.map(|phase| phase.action).unwrap_or("Open")),
        );
        card.insert("dismissAction".into(), json!("Dismiss"));
    }
    Json::Object(card)
}

/// The environment and thread of a thread link; empty when it is
/// not one (hal-c2 scheme, threads host, no query or fragment, two
/// decoded path parts).
pub fn parse_thread_link(link: &str) -> (String, String) {
    // Read by hand, not as a URL: QUrl and the url crate both
    // normalize the path (dot segments go, as a thread id of ".."
    // would), and the C++ decoded before it split, so an id holding
    // a "/" read as two parts there. Here the raw parts split first
    // and decode after, which is thread_link's own encoding read
    // back, and a malformed escape is no link (QUrl StrictMode
    // refused it too).
    fn decoded(part: &str) -> Option<String> {
        let bytes = part.as_bytes();
        let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
        let mut index = 0;
        while index < bytes.len() {
            if bytes[index] == b'%' {
                let hex = |byte: u8| (byte as char).to_digit(16).map(|digit| digit as u8);
                let high = bytes.get(index + 1).copied().and_then(hex)?;
                let low = bytes.get(index + 2).copied().and_then(hex)?;
                out.push(high * 16 + low);
                index += 3;
            } else {
                out.push(bytes[index]);
                index += 1;
            }
        }
        Some(String::from_utf8_lossy(&out).into_owned())
    }
    let Some(path) = link
        .get(.."hal-c2://threads/".len())
        .filter(|head| head.eq_ignore_ascii_case("hal-c2://threads/"))
        .map(|head| &link[head.len()..])
    else {
        return (String::new(), String::new());
    };
    if path.contains(['?', '#']) {
        return (String::new(), String::new());
    }
    let parts: Option<Vec<String>> = path
        .split('/')
        .filter(|part| !part.is_empty())
        .map(decoded)
        .collect();
    let Some(parts) = parts else {
        return (String::new(), String::new());
    };
    if parts.len() != 2 {
        return (String::new(), String::new());
    }
    (parts[0].clone(), parts[1].clone())
}

/// `hal-c2://threads/<environment>/<thread>` for a message's alert
/// or activity, from its link when that is one and otherwise from
/// the ids it names; empty when it names no thread.
pub fn thread_link(item: &Map<String, Json>) -> String {
    let link = item.get("link").and_then(Json::as_str).unwrap_or_default();
    if !parse_thread_link(link).0.is_empty() {
        return link.to_owned();
    }
    let environment = item
        .get("environmentId")
        .and_then(Json::as_str)
        .unwrap_or_default();
    let thread = item
        .get("threadId")
        .and_then(Json::as_str)
        .unwrap_or_default();
    if environment.is_empty() || thread.is_empty() {
        return String::new();
    }
    fn encode(part: &str) -> String {
        // QUrl::toPercentEncoding: everything but the unreserved set.
        let mut out = String::new();
        for byte in part.bytes() {
            match byte {
                b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                    out.push(byte as char)
                }
                _ => out.push_str(&format!("%{byte:02X}")),
            }
        }
        out
    }
    format!(
        "hal-c2://threads/{}/{}",
        encode(environment),
        encode(thread)
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::push_crypto::encrypt;

    const NOW: i64 = 1_790_000_000_000;

    fn device(now: i64) -> Device {
        Device {
            now,
            foreground: false,
            permitted: true,
            sdk: 36,
        }
    }

    fn alert_message(sent_at: i64) -> Map<String, Json> {
        object_of(&json!({
            "v": 1,
            "sentAt": sent_at as f64,
            "alert": {
                "id": "env-a:thread-1:completed:run-1",
                "kind": "completed",
                "title": "Fix checkout",
                "body": "Agent finished",
                "environmentId": "env-a",
                "threadId": "thread-1",
            }
        }))
    }

    #[test]
    fn an_alert_shows_once_and_an_encrypted_one_opens() {
        let dir = tempfile::tempdir().unwrap();
        let inbox = Inbox::new(dir.path());
        let effects = inbox.deliver(&alert_message(NOW), &device(NOW));
        assert_eq!(
            effects["alert"]["link"],
            json!("hal-c2://threads/env-a/thread-1")
        );
        // Again: already shown.
        let effects = inbox.deliver(&alert_message(NOW), &device(NOW));
        assert!(effects.get("alert").is_none());
        // Stale and unpermitted ones record nothing.
        let effects = inbox.deliver(&alert_message(NOW - 11 * MINUTE), &device(NOW));
        assert!(effects.get("alert").is_none());

        let keys = inbox.keys();
        assert!(keys.valid());
        let plain = serde_json::to_vec(&json!({
            "v": 1, "sentAt": NOW as f64,
            "alert": {"id": "env-a:thread-2:completed:run-1", "title": "Other",
                      "environmentId": "env-a", "threadId": "thread-2"}
        }))
        .unwrap();
        let body = encrypt(&plain, &keys.public_key, &keys.auth);
        let effects = inbox.receive(&body, &device(NOW));
        assert_eq!(
            effects["alert"]["link"],
            json!("hal-c2://threads/env-a/thread-2")
        );
    }

    #[test]
    fn a_dismissed_card_stays_away_until_a_run_starts_again() {
        let dir = tempfile::tempdir().unwrap();
        let inbox = Inbox::new(dir.path());
        let working = |at: i64| {
            object_of(&json!({
                "v": 1, "sentAt": at as f64,
                "activity": activity(vec![ActivityRow {
                    phase: "running".into(), title: "Fix checkout".into(),
                    project: "shop".into(), environment_id: "env-a".into(),
                    thread_id: "thread-1".into(), at,
                }], at),
            }))
        };
        let effects = inbox.deliver(&working(NOW), &device(NOW));
        assert_eq!(effects["card"]["ongoing"], json!(true));
        inbox.dismiss();
        assert!(inbox.dismissed());
        let effects = inbox.deliver(&working(NOW + 1000), &device(NOW + 1000));
        assert!(effects.get("card").is_none());
        let done = object_of(&json!({
            "v": 1, "sentAt": (NOW + 2000) as f64,
            "activity": activity(vec![ActivityRow {
                phase: "completed".into(), title: "Fix checkout".into(),
                project: "shop".into(), environment_id: "env-a".into(),
                thread_id: "thread-1".into(), at: NOW + 2000,
            }], NOW + 2000),
        }));
        inbox.deliver(&done, &device(NOW + 2000));
        // A run starting again brings the card back.
        let effects = inbox.deliver(&working(NOW + 3000), &device(NOW + 3000));
        assert_eq!(effects["card"]["chip"], json!("Working"));
    }

    #[test]
    fn forgetting_keeps_choices_and_thread_links_read_back() {
        let dir = tempfile::tempdir().unwrap();
        let inbox = Inbox::new(dir.path());
        let before = inbox.keys().public_key;
        inbox.set_value("distributor", json!("org.unifiedpush.example"));
        inbox.set_value("endpoint", json!("https://push.example/abc"));
        inbox.forget();
        assert_eq!(inbox.value("distributor"), json!("org.unifiedpush.example"));
        assert_eq!(inbox.value("endpoint"), Json::Null);
        assert_ne!(inbox.keys().public_key, before);

        assert_eq!(
            parse_thread_link("hal-c2://threads/env%20a/thread%2F1"),
            ("env a".to_string(), "thread/1".to_string())
        );
        assert_eq!(
            parse_thread_link("hal-c2://threads/env-a"),
            (String::new(), String::new())
        );
        assert_eq!(parse_thread_link("https://threads/env-a/t-1").0, "");
        assert_eq!(parse_thread_link("hal-c2://threads/env-a/t-1?x=1").0, "");
        // A malformed escape is no link, and dot segments are ids,
        // not path navigation.
        assert_eq!(parse_thread_link("hal-c2://threads/env-a/bad%ZZ").0, "");
        assert_eq!(
            parse_thread_link("hal-c2://threads/env-a/.."),
            ("env-a".to_string(), "..".to_string())
        );
        // A malformed override falls back to the ids named.
        let item = object_of(&json!({
            "link": "hal-c2://threads/env-a/bad%ZZ",
            "environmentId": "env-a",
            "threadId": "thread-1",
        }));
        assert_eq!(thread_link(&item), "hal-c2://threads/env-a/thread-1");
    }

    #[test]
    fn an_unreadable_file_is_left_intact_and_extreme_times_do_not_panic() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("push.json");
        std::fs::write(&path, "{broken").unwrap();
        let inbox = Inbox::new(dir.path());
        // No keys are made over it, and a change is not saved over it.
        assert!(!inbox.keys().valid());
        inbox.set_value("endpoint", json!("https://push.example/abc"));
        let effects = inbox.deliver(&alert_message(NOW), &device(NOW));
        assert!(effects.get("alert").is_none());
        assert_eq!(std::fs::read(&path).unwrap(), b"{broken");
        // Forget is the recovery: it replaces the file.
        inbox.forget();
        assert!(inbox.keys().valid());

        // An expiry at the ends of the number range ends the card,
        // it does not wrap into a day-long one.
        let message = object_of(&json!({
            "v": 1, "sentAt": NOW as f64,
            "activity": {"active": true, "expiresAt": -1e30, "rows": []},
        }));
        let effects = inbox.deliver(&message, &device(NOW));
        assert_eq!(effects["cancelCard"], json!(true));
        assert!(effects.get("card").is_none());
    }
}
