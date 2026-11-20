//! What the phone's root says of its layout (MobileApp's
//! `layout.desktop` interceptor): `MobileShell.qml` reports which
//! layout shows at start and as the window changes size, for the things
//! about it that live in controllers.
//!
//! The phone layout's home is the thread list, not a draft to land on,
//! and the desktop layout's is one. Only the phone's Space screen has
//! steps, so in the desktop layout the selected page is on show. The
//! desktop's terminals are in a drawer and the phone's one at a time on
//! a screen; the shell's Terminals has no single-screen switch yet, and
//! its timeline folds are the desktop's in both layouts until the
//! phone's folds are ported (H1, #1659).

use hal_c2_shell::controller::{self, Controller, Init};
use hal_c2_shell::controllers::drafts::DraftController;
use hal_c2_shell::controllers::space::Space;
use hal_c2_shell::json::Json;
use ljos::prelude::Engine;

pub struct MobileLayout;

impl Controller for MobileLayout {
    fn new(_init: Init<'_, Self>) -> Self {
        MobileLayout
    }

    fn activate(&mut self, engine: &Engine) {
        // A phone's window with no thread stays on the thread list, and
        // its Space screen has steps, until the root says the window
        // has room for the desktop's layout.
        apply(engine, false);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if action != "layout.desktop" {
            return false;
        }
        let shown = payload
            .get("shown")
            .and_then(Json::as_bool)
            .unwrap_or(false);
        apply(engine, shown);
        true
    }
}

fn apply(engine: &Engine, desktop: bool) {
    controller::with::<DraftController, _>(engine, |drafts, engine| {
        drafts.set_lands_on_draft(desktop);
        if desktop {
            drafts.land(engine);
        }
    });
    controller::with::<Space, _>(engine, |spaces, _| {
        spaces.set_page_shown_by_steps(!desktop);
    });
}
