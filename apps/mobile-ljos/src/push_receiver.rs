//! What PushReceiver.java and DismissReceiver.java call, whether
//! the app is running or the system started the process for them
//! alone (mobile-qt's PushSystem.cpp JNI entries): the inbox's
//! answer, as JSON, which Push.show renders.
//!
//! The Java sources are `apps/mobile-ljos/android/`'s, carried
//! from the Qt app's, waiting for Ljós's Android template slot for
//! app-supplied Java (hal-c2/ljos-ui#616) to bind these as JNI
//! exports (`Java_io_github_halc2_mobile_PushReceiver_receive` and
//! friends, `extern "system"` shims in the Android build). Until
//! then they are the plain Rust entry points those shims will
//! call, exercised here.
//!
//! `permitted` is the caller saying the system lets HAL-C2 post
//! notifications (Push.enabled): asking for that
//! (POST_NOTIFICATIONS on API 33+) is the Android PushSystem's
//! request_permission, which lands as a Ljós-dialect permission
//! type under #616 and slots into
//! [`crate::push_system::PushSystem::request_permission`] with no
//! change here or in Notifications.

use std::path::Path;

use crate::push_inbox::{self, Device, Inbox};

fn device(permitted: bool, sdk: i32) -> Device {
    Device {
        now: chrono::Utc::now().timestamp_millis(),
        foreground: push_inbox::foreground(),
        permitted,
        sdk,
    }
}

/// An encrypted push from the distributor, for the inbox at
/// `data_dir`: the effects Push.show renders, as JSON.
pub fn receive(data_dir: &Path, body: &[u8], permitted: bool, sdk: i32) -> String {
    Inbox::new(data_dir)
        .receive(body, &device(permitted, sdk))
        .to_string()
}

/// The endpoint the distributor gave this phone. The app, when it
/// runs, registers the new endpoint with its MC: its PushSystem
/// tells it the endpoint changed (the changed hook the Android
/// system fires from its receiver, #616).
pub fn endpoint(data_dir: &Path, endpoint: &str) {
    Inbox::new(data_dir).set_value("endpoint", endpoint.into());
}

/// The card was dismissed on the system side: what to render now.
pub fn dismiss(data_dir: &Path) -> String {
    Inbox::new(data_dir).dismiss().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::push_crypto::encrypt;
    use serde_json::json;

    #[test]
    fn a_receiver_opens_records_and_dismisses_through_the_inbox_file() {
        let dir = tempfile::tempdir().unwrap();
        let data = dir.path();
        // An endpoint the distributor gave, kept for the app.
        endpoint(data, "https://push.example/abc");
        assert_eq!(
            Inbox::new(data).value("endpoint"),
            json!("https://push.example/abc")
        );
        // A push the distributor carried, opened with this phone's keys.
        let keys = Inbox::new(data).keys();
        let plain = serde_json::to_vec(&json!({
            "v": 1,
            "sentAt": chrono::Utc::now().timestamp_millis() as f64,
            "alert": {"id": "env-a:thread-1:completed:run-1", "title": "Fix checkout",
                      "environmentId": "env-a", "threadId": "thread-1"}
        }))
        .unwrap();
        let body = encrypt(&plain, &keys.public_key, &keys.auth);
        let effects: serde_json::Value =
            serde_json::from_str(&receive(data, &body, true, 36)).unwrap();
        assert_eq!(
            effects["alert"]["link"],
            json!("hal-c2://threads/env-a/thread-1")
        );
        // Not permitted: nothing is shown and nothing is recorded,
        // so the same push shows once it may. A fresh alert id, so
        // the absence is the permission gate's doing, not dedup's:
        // the push above already recorded run-1 in `seen`.
        let plain = serde_json::to_vec(&json!({
            "v": 1,
            "sentAt": chrono::Utc::now().timestamp_millis() as f64,
            "alert": {"id": "env-a:thread-1:completed:run-2", "title": "Fix checkout",
                      "environmentId": "env-a", "threadId": "thread-1"}
        }))
        .unwrap();
        let body = encrypt(&plain, &keys.public_key, &keys.auth);
        let effects: serde_json::Value =
            serde_json::from_str(&receive(data, &body, false, 36)).unwrap();
        assert!(effects.get("alert").is_none());
        let effects: serde_json::Value =
            serde_json::from_str(&receive(data, &body, true, 36)).unwrap();
        assert_eq!(
            effects["alert"]["link"],
            json!("hal-c2://threads/env-a/thread-1"),
            "unpermitted recorded nothing, so the same push shows once it may"
        );
        // A dismissal takes the card down.
        let effects: serde_json::Value = serde_json::from_str(&dismiss(data)).unwrap();
        assert_eq!(effects["cancelCard"], json!(true));
        assert!(Inbox::new(data).dismissed());
    }
}
