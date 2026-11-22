//! The phone back from a long stay in the background, mobile-qt's
//! Resume: the system may have frozen its socket there without closing
//! it, and the check the client makes on coming to the foreground waits
//! seconds for an answer that will not come. After [`Resume::threshold`]
//! in the background, a connection that still looks ready is replaced
//! at once. A shorter stay is left to that check (the shell's
//! ConnectionHealth wakes the client on foreground, as on the desktop),
//! and a connection that is not ready to the client's own retry.
//!
//! The decision is ported and tested here; what reports the app's
//! foreground and background on Ljós is the Android host's AppState,
//! which has no host on a desktop build, so nothing feeds it yet (H1
//! wires it, #1659). On the host the shell's own foreground wake is the
//! whole behaviour.

/// The app's state as the system reports it, as Resume reads
/// Qt::ApplicationState.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AppState {
    Active,
    /// A notification shade or a system dialog over the app: no stay away.
    Inactive,
    Hidden,
    Suspended,
}

/// Whether the connection is replaced on this change.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Decision {
    Keep,
    Reconnect,
}

pub struct Resume {
    threshold_ms: i64,
    /// When the app went to the background; none while it is not there.
    since: Option<i64>,
}

impl Default for Resume {
    fn default() -> Self {
        Resume::new()
    }
}

impl Resume {
    pub fn new() -> Resume {
        Resume {
            threshold_ms: 10_000,
            since: None,
        }
    }

    pub fn set_threshold(&mut self, ms: i64) {
        self.threshold_ms = ms;
    }

    pub fn threshold(&self) -> i64 {
        self.threshold_ms
    }

    /// The app's state changed at `now` (milliseconds on a clock that
    /// keeps counting while the app is suspended); `ready` is whether
    /// the client still looks connected.
    pub fn state_changed(&mut self, state: AppState, now: i64, ready: bool) -> Decision {
        match state {
            AppState::Hidden | AppState::Suspended => {
                // Counted from when it left; a move from hidden to
                // suspended is the same stay.
                if self.since.is_none() {
                    self.since = Some(now);
                }
                Decision::Keep
            }
            AppState::Inactive => Decision::Keep,
            AppState::Active => {
                let since = self.since.take();
                if since.is_some_and(|since| now - since >= self.threshold_ms) && ready {
                    Decision::Reconnect
                } else {
                    Decision::Keep
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_long_stay_replaces_a_ready_connection_and_a_short_one_does_not() {
        let mut resume = Resume::new();
        assert_eq!(
            resume.state_changed(AppState::Hidden, 0, true),
            Decision::Keep
        );
        assert_eq!(
            resume.state_changed(AppState::Active, 9_999, true),
            Decision::Keep
        );
        resume.state_changed(AppState::Suspended, 20_000, true);
        // Hidden into suspended is the same stay, counted from hidden.
        resume.state_changed(AppState::Hidden, 25_000, true);
        assert_eq!(
            resume.state_changed(AppState::Active, 30_000, true),
            Decision::Reconnect
        );
        // A connection that is not ready is the client's own retry's.
        resume.state_changed(AppState::Hidden, 40_000, false);
        assert_eq!(
            resume.state_changed(AppState::Active, 90_000, false),
            Decision::Keep
        );
        // Inactive is no stay away.
        resume.state_changed(AppState::Inactive, 100_000, true);
        assert_eq!(
            resume.state_changed(AppState::Active, 200_000, true),
            Decision::Keep
        );
    }
}
