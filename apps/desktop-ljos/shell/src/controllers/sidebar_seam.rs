//! `sidebar`, read-only: the shell store's projects and threads through
//! SidebarModel's rules, as SidebarController::refresh publishes them, so
//! the bricks list what the MC has. Republished on every store change and
//! when the route moves to another thread.
//!
//! TODO(port): SidebarController — its actions (select, snooze, pin, reorder,
//! scope, rename, archive, delete), the selection and project scope, the
//! minute tick that ages the rows, `grouped`, announcing migrated threads
//! and visiting the open thread. This seam is what it replaces.

use std::collections::HashSet;
use std::rc::Rc;

use ljos::prelude::Engine;

use crate::bridge::Bridge;
use crate::controller::{Controller, Init, Me};
use crate::json::Json;
use crate::mc::Mc;
use crate::sidebar_model::{self as sidebar, GroupingSettings, Input};
use crate::store;

pub struct SidebarSeam {
    bridge: Bridge,
    mc: Rc<dyn Mc>,
    me: Me<Self>,
    /// The store and the route are followed once, from the first preview or
    /// activation on.
    following: bool,
}

impl Controller for SidebarSeam {
    fn new(init: Init<'_, Self>) -> Self {
        SidebarSeam {
            bridge: init.bridge,
            mc: init.mc,
            me: init.me,
            following: false,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        self.follow(engine);
        self.refresh(engine);
    }

    fn preview(&mut self, engine: &Engine) {
        self.follow(engine);
        self.refresh(engine);
    }
}

impl SidebarSeam {
    fn follow(&mut self, engine: &Engine) {
        if std::mem::replace(&mut self.following, true) {
            return;
        }
        let me = self.me.clone();
        store::on_changed(engine, move |engine| {
            me.run(engine, |c, engine| c.refresh(engine));
        });
        let me = self.me.clone();
        self.bridge.watch(engine, "route", move |engine, _| {
            me.run(engine, |c, engine| c.refresh(engine));
        });
    }

    fn refresh(&mut self, engine: &Engine) {
        let route = self.bridge.published(engine, "route");
        let active_thread_key = route
            .as_ref()
            .filter(|r| r["kind"] == "thread")
            .and_then(|r| r["threadKey"].as_str())
            .map(str::to_owned);
        let active_draft_id = route
            .as_ref()
            .filter(|r| r["kind"] == "draft")
            .map_or(Json::Null, |r| r["draftId"].clone());
        let own = self.mc.environment();
        let now_ms = chrono::Utc::now().timestamp_millis();
        let view = store::with(engine, |store| {
            let threads = store.threads();
            // TODO(port): Settings::grouping — the user's grouping and sort.
            let grouping = GroupingSettings::default();
            let input = Input {
                projects: sidebar::group_projects(&store.projects(), &grouping, &own, &threads),
                local_environment_id: (!own.is_empty()).then(|| own.clone()),
                offline_environments: store
                    .environments()
                    .into_iter()
                    .filter(|e| !store.environment_online(e))
                    .collect::<HashSet<_>>(),
                // TODO(port): DraftController::drafts and
                // ComposerController::draftPreview — the drafts listed.
                drafts: Vec::new(),
                active_thread_key,
                active_draft_id,
                // TODO(port): KeybindingController — the jump labels and
                // whether their hints show.
                // TODO(port): Settings::timestampFormat — describe_wake.
                ..Input::default()
            };
            Some(sidebar::build(
                &threads,
                &input,
                &None,
                &|environment| store.capabilities(environment),
                now_ms,
            ))
        });
        if let Some(view) = view {
            self.bridge.publish(engine, "sidebar", view.state);
        }
    }
}
