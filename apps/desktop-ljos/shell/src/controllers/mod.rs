//! The controllers ported so far, each a desktop-qt NativeController.

pub mod client_activity;
pub mod layout;
pub mod licenses;
pub mod navigation;
pub mod sidebar_seam;
pub mod theme;
pub mod usage_prices;

use crate::controller::{Registration, Scope};

/// Every controller the shell runs, as NativeControllerRegistrar lists them.
pub fn registrations() -> Vec<Registration> {
    vec![
        Registration::new::<client_activity::ClientActivity>("clientActivity", &[], Scope::Window),
        Registration::new::<layout::Layout>("layout", &["layout"], Scope::Window),
        Registration::new::<licenses::Licenses>("licenses", &["licenses"], Scope::Window),
        Registration::new::<navigation::Navigation>("navigation", &["route"], Scope::Window),
        Registration::new::<sidebar_seam::SidebarSeam>("sidebar", &["sidebar"], Scope::Window),
        Registration::new::<theme::Themes>("theme", &["theme"], Scope::Window),
        Registration::new::<usage_prices::UsagePrices>(
            "usagePrices",
            &["usagePrices"],
            Scope::Window,
        ),
    ]
}
