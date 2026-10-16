//! `clientActivity`, desktop-qt's ClientActivityController: tells the MC
//! this window is open (`server.reportClientActivity`), so its background
//! work (git fetches, provider checks) runs for what a client watches. A
//! report is a lease of LEASE_MS, renewed every REPORT_MS and on every new
//! connection.
//!
//! Not ported yet: the shown thread's and checkout's scopes (they wait for
//! the workspace controller) and focus (Ljós's `Application.state` is not
//! followed here yet), so a report names provider status only and says the
//! window is focused.

use std::sync::OnceLock;

use ljos::prelude::{Engine, ObjectId};
use serde_json::json;

use crate::controller::{self, Controller, Init, Me};
use crate::mc::Mc;

pub const REPORT_MS: i32 = 25_000;
pub const LEASE_MS: i32 = 45_000;

pub struct ClientActivity {
    mc: std::rc::Rc<dyn Mc>,
    me: Me<Self>,
    renew: Option<ObjectId>,
}

impl Controller for ClientActivity {
    fn new(init: Init<'_, Self>) -> Self {
        ClientActivity {
            mc: init.mc,
            me: init.me,
            renew: None,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.renew.is_some() {
            return;
        }
        let me = self.me.clone();
        self.renew = controller::every(engine, None, REPORT_MS, move |engine| {
            me.run(engine, |c, engine| c.report(engine));
        });
        // A new connection holds none of this client's leases.
        let me = self.me.clone();
        self.mc.on_ready_changed(Box::new(move |engine, ready| {
            if ready {
                me.run(engine, |c, engine| c.report(engine));
            }
        }));
        self.report(engine);
    }
}

impl ClientActivity {
    fn report(&self, _engine: &Engine) {
        if !self.mc.is_ready() {
            return;
        }
        let environment = self.mc.environment();
        let payload = json!({
            "environmentId": environment,
            "clientId": client_id(),
            "clientKind": "desktop-renderer",
            "visible": true,
            "focused": true,
            "recentlyInteracted": true,
            "appState": "active",
            "scopes": [{ "type": "provider-status" }],
            "ttlMs": LEASE_MS,
            "observedAt": now_iso8601(),
        });
        self.mc.call(
            &environment,
            "server.reportClientActivity",
            payload,
            Box::new(|_, _| {}),
        );
    }
}

/// This run's id for its leases, with the window's; a restarted app's old
/// leases run out on their own.
fn client_id() -> String {
    static PROCESS: OnceLock<String> = OnceLock::new();
    let process = PROCESS.get_or_init(|| {
        let mut bytes = [0u8; 16];
        // Unique enough without a random source: the clock and the pid.
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos());
        bytes[..12].copy_from_slice(&nanos.to_le_bytes()[..12]);
        bytes[12..].copy_from_slice(&std::process::id().to_le_bytes());
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    });
    format!("{process}:main")
}

/// UTC now as `2026-10-16T12:00:00.000Z`.
fn now_iso8601() -> String {
    let ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis()) as i64;
    let (days, rest) = (ms.div_euclid(86_400_000), ms.rem_euclid(86_400_000));
    // Civil from days (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z",
        rest / 3_600_000,
        rest / 60_000 % 60,
        rest / 1000 % 60,
        rest % 1000
    )
}
