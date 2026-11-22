//! `notifications`: the stand-in for mobile-qt's Notifications (with
//! push/PushInbox, PushCrypto and PushSystem) until push is ported
//! (H1, #1659).
//!
//! The real one registers a UnifiedPush endpoint with the paired MC
//! (`hal-c2.registerPush`), and the push inbox decides what of each push
//! the system shows. A host build can receive no push, so this publishes
//! the same shape with `supported: false` and every action answered.
//! The one piece the phone's screens act on without a system behind it,
//! the threads whose alerts are muted, is real: `alerts.setMuted` keeps
//! the list ThreadScreen reads, in memory until H1 keeps it with the
//! inbox's file as the Qt client does.
//!
//! Publishes `notifications`:
//!   {supported, permission: granted | denied | ask, enabled,
//!    distributors: [{id, label}], distributor, choosing, liveActivity,
//!    liveUpdates, quietHours, muted: [thread keys], message}
//!
//! Actions: `notifications.enable`, `notifications.disable`,
//! `notifications.openSettings`, `notifications.pickDistributor {id}`,
//! `notifications.setLiveActivity {on}`,
//! `notifications.openLiveUpdateSettings`,
//! `notifications.setQuietHours {quietHours}`, and
//! `alerts.setMuted {key, muted}` for one thread.

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controller::{Controller, Init};
use hal_c2_shell::json::Json;
use ljos::prelude::Engine;
use serde_json::json;

const KEY: &str = "notifications";

pub struct Notifications {
    bridge: Bridge,
    /// The keys ("<environment>:<thread id>") whose alerts are muted.
    muted: Vec<String>,
    /// Null, or {start, end, allowApprovals} in minutes after midnight.
    quiet_hours: Json,
    live_activity: bool,
}

impl Controller for Notifications {
    fn new(init: Init<'_, Self>) -> Self {
        Notifications {
            bridge: init.bridge,
            muted: Vec::new(),
            quiet_hours: Json::Null,
            live_activity: false,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        match action {
            "alerts.setMuted" => {
                let key = payload
                    .get("key")
                    .and_then(Json::as_str)
                    .unwrap_or_default()
                    .to_owned();
                let muted = payload
                    .get("muted")
                    .and_then(Json::as_bool)
                    .unwrap_or(false);
                self.set_muted(&key, muted);
            }
            "notifications.setQuietHours" => {
                self.quiet_hours = payload.get("quietHours").cloned().unwrap_or(Json::Null);
            }
            "notifications.setLiveActivity" => {
                self.live_activity = payload.get("on").and_then(Json::as_bool).unwrap_or(false);
            }
            // Nothing to enable or open without a push system; the
            // published state (supported: false) is the answer.
            "notifications.enable"
            | "notifications.disable"
            | "notifications.openSettings"
            | "notifications.pickDistributor"
            | "notifications.openLiveUpdateSettings" => {}
            _ => return false,
        }
        self.publish(engine);
        true
    }
}

/// Mutes or unmutes one thread in `muted`: a key held once, an empty
/// key never.
pub fn apply_muted(muted: &mut Vec<String>, key: &str, on: bool) {
    let held = muted.iter().any(|held| held == key);
    match (on, held) {
        (true, false) if !key.is_empty() => muted.push(key.to_owned()),
        (false, true) => muted.retain(|held| held != key),
        _ => {}
    }
}

impl Notifications {
    fn set_muted(&mut self, key: &str, muted: bool) {
        apply_muted(&mut self.muted, key, muted);
    }

    fn publish(&self, engine: &Engine) {
        self.bridge.publish(
            engine,
            KEY,
            json!({
                "supported": false,
                "permission": "ask",
                "enabled": false,
                "distributors": [],
                "distributor": "",
                "choosing": false,
                "liveActivity": self.live_activity,
                "liveUpdates": false,
                "quietHours": self.quiet_hours,
                "muted": self.muted,
                "message": "",
            }),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::apply_muted;

    #[test]
    fn muting_keeps_a_key_once_and_unmuting_takes_it_off() {
        let mut muted: Vec<String> = Vec::new();
        apply_muted(&mut muted, "e:t", true);
        apply_muted(&mut muted, "e:t", true);
        apply_muted(&mut muted, "", true);
        assert_eq!(muted, ["e:t"]);
        apply_muted(&mut muted, "e:t", false);
        assert!(muted.is_empty());
    }
}
