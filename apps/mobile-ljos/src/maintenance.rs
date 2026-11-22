//! `maintenance`: the stand-in for mobile-qt's Maintenance until it is
//! ported (H1, #1659).
//!
//! The real one is the phone's care of the environments it reaches:
//! each machine's HAL-C2 version against this app's and the newest
//! release on its channel, the update to that version, and the enabled
//! providers on it with their updates. This publishes the same shape
//! with no machines known yet, so the connection notice's update button
//! stays away and the Maintenance settings page says there is nothing
//! to update.
//!
//! Publishes `maintenance`:
//!   {appVersion,
//!    machines: [{environmentId, label, version, online, local, blocked,
//!                path: update | desktop | desktop-manual | command,
//!                target, command, updating, outcome, release,
//!                providers: [...], providersError}],
//!    updatable, groups: [{driver, name, count}], confirm, message}
//!
//! Actions: `maintenance.open`, `maintenance.close`,
//! `maintenance.check {environment}`, `maintenance.update
//! {environment}`, `maintenance.updateAll`, `maintenance.confirm`,
//! `maintenance.cancel`, `maintenance.copyCommand {environment}`,
//! `maintenance.refreshProviders {environment}`,
//! `maintenance.updateProvider {environment, instanceId}` and
//! `maintenance.updateProviders {driver}`.

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controller::{Controller, Init};
use hal_c2_shell::json::Json;
use ljos::prelude::Engine;
use serde_json::json;

const KEY: &str = "maintenance";

pub struct Maintenance {
    bridge: Bridge,
}

impl Controller for Maintenance {
    fn new(init: Init<'_, Self>) -> Self {
        Maintenance {
            bridge: init.bridge,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, _payload: &Json) -> bool {
        if !action.starts_with("maintenance.") {
            return false;
        }
        self.publish(engine);
        true
    }
}

impl Maintenance {
    fn publish(&self, engine: &Engine) {
        self.bridge.publish(
            engine,
            KEY,
            json!({
                "appVersion": env!("CARGO_PKG_VERSION"),
                "machines": [],
                "updatable": 0,
                "groups": [],
                "confirm": null,
                "message": null,
            }),
        );
    }
}
