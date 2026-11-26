//! The MC a client connects to: its origin and the token for it, and what
//! the pairing said of it.

use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    pub origin: String,
    pub token: String,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub environment_id: String,
    /// When the credential runs out, if the MC said (kept as the
    /// pairing files write it, ISO with milliseconds; the client
    /// renews it before then).
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub expires_at: String,
}

impl Session {
    /// [`Session::expires_at`] as a time; none when the MC never said.
    pub fn expiry(&self) -> Option<DateTime<Utc>> {
        let parsed = DateTime::parse_from_rfc3339(&self.expires_at).ok()?;
        Some(parsed.with_timezone(&Utc))
    }
}

/// A credential expiry as the pairing files keep it; empty for none.
pub fn expires_text(expires_at: Option<DateTime<Utc>>) -> String {
    expires_at
        .map(|at| at.to_rfc3339_opts(SecondsFormat::Millis, true))
        .unwrap_or_default()
}
