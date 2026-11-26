//! The device's side of notifications as the app
//! ([`crate::notifications`]) uses it, mobile-qt's push/PushSystem:
//! whether HAL-C2 may post them, asking for that, the UnifiedPush
//! distributors installed and an endpoint from one, and putting up
//! what the push inbox ([`crate::push_inbox`]) says to. The endpoint
//! itself is kept in the inbox's file, where Android's receiver
//! writes it while the app may not be running. The scenarios put one
//! of their own here (mobile-qt's tests/FakePushSystem.h).
//!
//! Android's side (Push.java over JNI) waits for Ljós's Android
//! platform seam (hal-c2/ljos-ui#616), so the device's system here
//! is the unsupported one, as mobile-qt's off Android: a host build
//! can receive no push.

use std::rc::Rc;

use chrono::Utc;
use hal_c2_shell::json::Json;
use ljos::prelude::Engine;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Permission {
    Granted,
    Denied,
    Ask,
}

impl Permission {
    pub fn name(self) -> &'static str {
        match self {
            Permission::Granted => "granted",
            Permission::Denied => "denied",
            Permission::Ask => "ask",
        }
    }
}

#[derive(Clone, Debug)]
pub struct Distributor {
    /// Its package.
    pub id: String,
    /// What the user knows it as.
    pub label: String,
}

/// The endpoint changed, or went: on the app's thread.
pub type Changed = Rc<dyn Fn(&Engine)>;

/// The system's word on asking for permission, once.
pub type Answered = Rc<dyn Fn(&Engine, Permission)>;

pub trait PushSystem {
    /// Whether this build can receive pushes at all.
    fn supported(&self) -> bool;
    /// Android's API level; 0 off Android.
    fn sdk(&self) -> i32;
    fn permission(&self) -> Permission;
    /// Asks the user, where the system still does. `answered` is
    /// called once with the system's word afterwards.
    fn request_permission(&self, engine: &Engine, answered: Answered);
    /// HAL-C2's page of notification settings in the system's
    /// settings.
    fn open_settings(&self);
    /// Android 16's page for live updates.
    fn open_live_update_settings(&self);
    fn distributors(&self) -> Vec<Distributor>;
    /// Asks `distributor` for an endpoint for this phone, which
    /// reaches the inbox later; [`PushSystem::set_changed`]'s runs.
    fn subscribe(&self, distributor: &str);
    fn unsubscribe(&self);
    /// Puts up, replaces or takes down notifications as the inbox's
    /// effects say.
    fn show(&self, effects: &Json);
    /// Wall clock, ms since the epoch.
    fn now(&self) -> i64 {
        Utc::now().timestamp_millis()
    }
    fn set_changed(&self, changed: Changed);
}

/// A build that cannot receive pushes: off Android, where no
/// distributor runs (PushSystem.cpp's Unsupported).
#[derive(Default)]
pub struct Unsupported {
    changed: std::cell::RefCell<Option<Changed>>,
}

impl PushSystem for Unsupported {
    fn supported(&self) -> bool {
        false
    }

    fn sdk(&self) -> i32 {
        0
    }

    fn permission(&self) -> Permission {
        Permission::Denied
    }

    fn request_permission(&self, engine: &Engine, answered: Answered) {
        answered(engine, Permission::Denied);
    }

    fn open_settings(&self) {}

    fn open_live_update_settings(&self) {}

    fn distributors(&self) -> Vec<Distributor> {
        Vec::new()
    }

    fn subscribe(&self, _distributor: &str) {}

    fn unsubscribe(&self) {}

    fn show(&self, _effects: &Json) {}

    fn set_changed(&self, changed: Changed) {
        *self.changed.borrow_mut() = Some(changed);
    }
}

/// This device's: Android's notifications and UnifiedPush once Ljós
/// hosts them (#616), or a system that supports none of it.
pub fn device_push_system() -> Rc<dyn PushSystem> {
    Rc::new(Unsupported::default())
}
