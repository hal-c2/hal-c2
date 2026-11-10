//! `stage`, desktop-qt's StageController: which build the window is, said
//! at a glance: a development shell, or one talking to a Nightly MC, marks
//! the sidebar's brand band with its artwork or a version pill, as
//! Settings → Appearance's Environment identification chooses.
//!
//! Publishes `stage`: {label ("Dev", "Nightly", or empty for a release),
//! artwork ("dev", "nightly" or null), pill (the label or null)}. The
//! Sidebar brick draws it; the window title carries the label.

use std::cell::RefCell;

use ljos::prelude::Engine;
use serde_json::json;

thread_local! {
    static APP_STAGE: RefCell<String> = const { RefCell::new(String::new()) };
}

/// The app's own stage, set before the first window ("Dev" for a
/// development shell; empty for a release).
pub fn set_app_stage(stage: &str) {
    APP_STAGE.with(|s| *s.borrow_mut() = stage.to_owned());
}

fn app_stage() -> String {
    APP_STAGE.with(|s| s.borrow().clone())
}

use crate::bridge::Bridge;
use crate::controller::{Controller, Init, Me};
use crate::controllers::settings::Settings;
use crate::json::Json;
use crate::store;

pub struct Stage {
    bridge: Bridge,
    me: Me<Stage>,
    mc: std::rc::Rc<dyn crate::mc::Mc>,
    active: bool,
}

impl Controller for Stage {
    fn new(init: Init<'_, Self>) -> Self {
        Stage {
            bridge: init.bridge,
            me: init.me,
            mc: init.mc,
            active: false,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let me = self.me.clone();
        store::on_changed(engine, move |engine| {
            me.run(engine, |c, engine| c.publish(engine));
        });
        let me = self.me.clone();
        Settings::of(engine).on_device_changed(move |engine| {
            me.run(engine, |c, engine| c.publish(engine));
        });
        self.publish(engine);
    }

    fn handle(&mut self, _engine: &Engine, _action: &str, _payload: &Json) -> bool {
        false
    }
}

/// Whether `version` is a nightly or preview build's:
/// `<base>-(nightly|preview).<yyyymmdd>.<n>`.
fn is_nightly(version: &str) -> bool {
    let Some((base, rest)) = version.split_once(['-']) else {
        return false;
    };
    // The base holds no "-" or "+", and is not empty.
    if base.is_empty() || base.contains('+') {
        return false;
    }
    let Some(rest) = rest
        .strip_prefix("nightly.")
        .or_else(|| rest.strip_prefix("preview."))
    else {
        return false;
    };
    let Some((date, build)) = rest.split_once('.') else {
        return false;
    };
    date.len() == 8
        && date.bytes().all(|b| b.is_ascii_digit())
        && !build.is_empty()
        && build.bytes().all(|b| b.is_ascii_digit())
}

impl Stage {
    /// The app's own stage, else "Nightly" for a nightly or preview build
    /// of the MC.
    fn label(&self, engine: &Engine) -> String {
        let own = app_stage();
        if !own.is_empty() {
            return own;
        }
        let environment = self.mc.environment();
        let version = store::with(engine, |s| {
            s.environment(&environment)
                .get("serverVersion")
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned()
        });
        if is_nightly(&version) {
            "Nightly".to_owned()
        } else {
            String::new()
        }
    }

    fn publish(&self, engine: &Engine) {
        if !self.active {
            return;
        }
        let stage = self.label(engine);
        let mode = Settings::of(engine)
            .setting(engine, "environmentIdentificationMode")
            .and_then(|v| v.as_str().map(str::to_owned))
            .unwrap_or_default();
        let marked = !stage.is_empty();
        // `publish` skips a state that has not changed.
        self.bridge.publish(
            engine,
            "stage",
            json!({
                "label": stage,
                "artwork": (marked && mode == "artwork").then(|| stage.to_lowercase()),
                "pill": (marked && mode == "pill").then_some(stage),
            }),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::is_nightly;

    #[test]
    fn nightly_versions_are_told_from_releases() {
        assert!(is_nightly("0.0.23-nightly.20260101.4"));
        assert!(is_nightly("1.2.3-preview.20260101.12"));
        assert!(!is_nightly("0.0.23"));
        assert!(!is_nightly("0.0.23-nightly.2026010.4"));
        assert!(!is_nightly("0.0.23-nightly.20260101."));
        assert!(!is_nightly("0.0.23-rc.20260101.4"));
        assert!(!is_nightly("0.0.23+x-nightly.20260101.4"));
        assert!(!is_nightly("-nightly.20260101.4"));
    }
}
