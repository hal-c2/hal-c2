//! The controllers ported so far, each a desktop-qt NativeController.

pub mod client_activity;
pub mod layout;
pub mod navigation;
pub mod theme;

use crate::controller::{Registration, Scope};

/// Every controller the shell runs, as NativeControllerRegistrar lists them.
pub fn registrations() -> Vec<Registration> {
    vec![
        Registration::new::<client_activity::ClientActivity>("clientActivity", &[], Scope::Window),
        Registration::new::<layout::Layout>("layout", &["layout"], Scope::Window),
        Registration::new::<navigation::Navigation>("navigation", &["route"], Scope::Window),
        Registration::new::<theme::Themes>("theme", &["theme"], Scope::Window),
    ]
}
