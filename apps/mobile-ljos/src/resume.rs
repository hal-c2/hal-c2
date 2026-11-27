//! The phone back from a long stay in the background, mobile-qt's
//! Resume: the system may have frozen its socket there without closing
//! it, and the check the client makes on coming to the foreground waits
//! seconds for an answer that will not come. After [`Resume::threshold`]
//! in the background, a connection that still looks ready is replaced
//! at once. A shorter stay is left to that check (the shell's
//! ConnectionHealth wakes the client on foreground, as on the desktop),
//! and a connection that is not ready to the client's own retry.
//!
//! [`ResumeConnection`] feeds it the Ljós Application's state (the
//! Android host's AppState on a phone, the window's on a host build)
//! and replaces the connection when it says, beside the shell's own
//! foreground wake, which only checks a waiting retry.

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

/// The Application state's Qt number as the decision reads it
/// (Qt::ApplicationState: suspended 0, hidden 1, inactive 2,
/// active 4); another number is no change it knows.
pub fn app_state(qt_value: i32) -> Option<AppState> {
    match qt_value {
        0 => Some(AppState::Suspended),
        1 => Some(AppState::Hidden),
        2 => Some(AppState::Inactive),
        4 => Some(AppState::Active),
        _ => None,
    }
}

/// Mobile-qt's Resume as MobileApp owns it: the Application's state
/// in, the client's reconnect out, on the wall clock that keeps
/// counting while the app is suspended (QDateTime's). Publishes
/// nothing; the connection's phases are ConnectionHealth's.
pub struct ResumeConnection {
    resume: Resume,
    mc: std::rc::Rc<dyn hal_c2_shell::mc::Mc>,
}

impl ResumeConnection {
    fn state_changed(&mut self, engine: &ljos::prelude::Engine) {
        let Ok(app) = engine.singleton::<ljos::prelude::Application>() else {
            return;
        };
        let Some(state) = (match engine.read_by_name(app, "state") {
            ljos::prelude::Value::Int(value) => app_state(value),
            _ => None,
        }) else {
            return;
        };
        let now = chrono::Utc::now().timestamp_millis();
        if self.resume.state_changed(state, now, self.mc.is_ready()) == Decision::Reconnect {
            self.mc.reconnect();
        }
    }
}

impl hal_c2_shell::controller::Controller for ResumeConnection {
    fn new(init: hal_c2_shell::controller::Init<'_, Self>) -> Self {
        if let Ok(app) = init.engine.singleton::<ljos::prelude::Application>() {
            let me = init.me.clone();
            let _ = init
                .engine
                .connect_by_name(app, "stateChanged", move |engine, _| {
                    me.run(engine, |c: &mut ResumeConnection, engine| {
                        c.state_changed(engine)
                    });
                });
        }
        ResumeConnection {
            resume: Resume::new(),
            mc: init.mc,
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

    #[test]
    fn qt_state_numbers_read_as_the_states() {
        assert_eq!(app_state(0), Some(AppState::Suspended));
        assert_eq!(app_state(1), Some(AppState::Hidden));
        assert_eq!(app_state(2), Some(AppState::Inactive));
        assert_eq!(app_state(4), Some(AppState::Active));
        assert_eq!(app_state(3), None);
    }
}
