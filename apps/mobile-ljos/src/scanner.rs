//! `scanner`: the stand-in for mobile-qt's Scanner (with ScanCamera and
//! QrReader) until the phone has a camera on Ljós (H1, #1659).
//!
//! The real one runs the camera only while the scanner is open, the app
//! may use it, the screen has handed over its preview's sink and the app
//! is at the front, and pairs at once with a pairing code it reads. A
//! host build has no camera to run, so this publishes the same shape
//! with the camera denied and says so: the pairing screen's field still
//! takes a link, which is how a host build pairs. `ScanScreen` shows the
//! denied panel for it, as a device that refuses the camera does.
//!
//! Publishes `scanner`:
//!   {open, access: unknown | asking | granted | denied,
//!    failed, message}
//!
//! Actions: `scanner.open`, `scanner.close`, `scanner.preview {sink}`,
//! `scanner.settings`, `scanner.retry`.

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controller::{Controller, Init};
use hal_c2_shell::json::Json;
use ljos::prelude::Engine;
use serde_json::json;

const KEY: &str = "scanner";

/// What the stub says while open, in ScanScreen's denied panel's place:
/// the screen's own words already tell the user to enter the link.
const MESSAGE: &str = "";

pub struct Scanner {
    bridge: Bridge,
    open: bool,
}

impl Controller for Scanner {
    fn new(init: Init<'_, Self>) -> Self {
        Scanner {
            bridge: init.bridge,
            open: false,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, _payload: &Json) -> bool {
        match action {
            "scanner.open" => self.open = true,
            "scanner.close" => self.open = false,
            // No camera runs however the screen asks; the published
            // state already says so.
            "scanner.preview" | "scanner.settings" | "scanner.retry" => {}
            _ => return false,
        }
        self.publish(engine);
        true
    }
}

impl Scanner {
    fn publish(&self, engine: &Engine) {
        self.bridge.publish(
            engine,
            KEY,
            json!({
                "open": self.open,
                "access": if self.open { "denied" } else { "unknown" },
                "failed": false,
                "message": MESSAGE,
            }),
        );
    }
}
