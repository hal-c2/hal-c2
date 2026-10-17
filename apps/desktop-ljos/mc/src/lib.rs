//! The desktop's own protocol-3 connection to its MC (apps/server-ex
//! lib/hal_c2/web/protocol.ex), ported from apps/desktop-qt's `McClient`.
//!
//! Two halves, on two sides of a thread boundary:
//!
//! * [`spawn`] starts the I/O thread and gives a [`McHandle`]: cheap to clone,
//!   `Send`, and the only way commands reach the connection. Everything the
//!   connection has to say (frames per subscription, replies, status) goes to
//!   the sink given to [`spawn`], as [`McEvent`]s in the order they happened.
//! * [`McClient`] lives on the thread that owns the UI (it is `!Send`). It
//!   holds the callbacks: each subscription's frame handler and `resume`, and
//!   each call's reply. The sink forwards every event to that thread, which
//!   hands it to [`McClient::deliver`].
//!
//! Subscriptions are owned by the UI side, because only whoever holds the data
//! can say where a stream continues. The I/O thread never asks it: each
//! `hello` is announced as a [`Status`] with a new [`Status::connection`], and
//! the client answers by sending every subscription again with a fresh
//! `resume`. A `sub` names the connection it was made for and the I/O thread
//! drops one meant for an older connection, so a subscription is never sent
//! twice on one socket, however events and commands cross.

mod client;
mod core;
mod driver;
mod http;
pub mod pairing;
#[cfg(test)]
mod prop;

use std::sync::Arc;
use std::time::Duration;

use serde_json::{Map, Value};

pub use client::{AuthorizedRequest, ListenerId, McClient, SubId, WeakMcClient};
pub use driver::{McHandle, spawn};
pub use http::fetch;

/// The protocol this client speaks (apps/server-ex `HalC2.Web.Protocol`).
pub const PROTOCOL: i64 = 3;

/// A frame as the MC sent it: a JSON object with its type in `t`.
pub type Frame = Map<String, Value>;

/// Where the connection is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    /// Never opened, or closed.
    Closed,
    /// Reading the descriptor, opening the socket, waiting for hello.
    Connecting,
    /// The MC said hello.
    Ready,
    /// Dropped or unreachable: the next attempt is scheduled ([`Status::retry_delay`]).
    Retrying,
    /// This device has no network: waits for it.
    Offline,
    /// The MC refuses the credential: waits for the user to pair again.
    Refused,
    /// The MC speaks another protocol ([`Status::blocked_protocol`]): one side must update.
    Blocked,
}

/// What the connection says about itself, sent whole whenever any of it changes.
#[derive(Clone, Debug, PartialEq)]
pub struct Status {
    pub phase: Phase,
    /// While ready, which hello this is: each connection has its own number, so
    /// a new one is how the owner knows to send its subscriptions again.
    pub connection: Option<u64>,
    /// Why the last connection ended or could not be made ("timeout", "closed",
    /// or the socket's own words); empty while none has failed since it was ready.
    pub failure: String,
    /// The W3C trace id of the attempt that failed, sent as `traceparent` with
    /// its requests; empty when none failed.
    pub failure_trace_id: String,
    /// The delay before the scheduled retry ([`Phase::Retrying`]).
    pub retry_delay: Duration,
    /// How many retries were scheduled in a row; each scheduled retry is a new
    /// status even when its delay is the last one's.
    pub retries: u32,
    /// The protocol the MC's descriptor declares, when it blocks the connection.
    pub blocked_protocol: Option<i64>,
    /// The MC's descriptor as last read (label, serverVersion, ...).
    pub descriptor: Arc<Map<String, Value>>,
    /// The MC's node name, from its hello.
    pub mc: String,
    /// The environment the MC itself serves, for calls about the MC (its
    /// cluster); empty until the first hello.
    pub environment: String,
}

impl Default for Status {
    fn default() -> Self {
        Self {
            phase: Phase::Closed,
            connection: None,
            failure: String::new(),
            failure_trace_id: String::new(),
            retry_delay: Duration::ZERO,
            retries: 0,
            blocked_protocol: None,
            descriptor: Arc::default(),
            mc: String::new(),
            environment: String::new(),
        }
    }
}

impl Status {
    pub fn is_ready(&self) -> bool {
        self.connection.is_some()
    }
}

/// Why a call failed: the MC's message, or "not connected" / "disconnected"
/// when the socket was not there to carry it. `detail` is the contract error
/// (`{"_tag", ...fields}`) when the MC sent one, or the refused HTTP body.
#[derive(Clone, Debug, PartialEq)]
pub struct CallError {
    pub message: String,
    pub detail: Value,
}

impl CallError {
    pub(crate) fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            detail: Value::Null,
        }
    }

    pub(crate) fn not_connected() -> Self {
        Self::new("not connected")
    }

    pub(crate) fn disconnected() -> Self {
        Self::new("disconnected")
    }
}

impl std::fmt::Display for CallError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for CallError {}

/// Everything the I/O thread tells its owner. Hand each to
/// [`McClient::deliver`] on the owning thread, all of them, in order: a lost
/// frame leaves a stream's copy wrong.
#[derive(Clone, Debug)]
pub enum McEvent {
    /// The connection's status changed.
    Status(Status),
    /// A frame for subscription `id`.
    Frame { id: u64, frame: Frame },
    /// The answer to call, post or upload `id`.
    Reply {
        id: u64,
        result: Result<Value, CallError>,
    },
    /// The answer to download `id`.
    Bytes {
        id: u64,
        result: Result<Vec<u8>, CallError>,
    },
    /// A ping was answered (`true`), or was not in time and the socket is replaced.
    Checked(bool),
}

/// A fresh W3C trace id: 32 hex digits.
pub(crate) fn new_trace_id() -> String {
    hex(&random::<16>())
}

/// A fresh random (v4) UUID, as `orchestration.dispatchCommand` takes for its commandId.
pub fn new_uuid() -> String {
    let mut bytes = random::<16>();
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let h = hex(&bytes);
    format!(
        "{}-{}-{}-{}-{}",
        &h[0..8],
        &h[8..12],
        &h[12..16],
        &h[16..20],
        &h[20..32]
    )
}

fn random<const N: usize>() -> [u8; N] {
    let mut bytes = [0u8; N];
    getrandom::fill(&mut bytes).expect("the system has no randomness");
    bytes
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
