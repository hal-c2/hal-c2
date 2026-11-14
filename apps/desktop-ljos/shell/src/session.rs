//! The MC a client connects to: its origin and the token for it, and what
//! the pairing said of it.

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
}
