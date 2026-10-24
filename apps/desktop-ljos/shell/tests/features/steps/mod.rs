//! The step definitions, one file per desktop-qt steps file
//! (apps/desktop-qt/tests/native/features/<Name>Steps.cpp → `<name>.rs`),
//! each registering its steps and fake MC handlers in `register`.

use crate::harness::Steps;

pub mod connection;
pub mod connection_health;
pub mod draft;
pub mod header;
pub mod mc;
pub mod navigation;
pub mod orchestration_view;
pub mod plan;
pub mod stash;
pub mod storage_layout;
pub mod stream;
pub mod thread_menu;
pub mod thread_snooze;
pub mod timeline;
pub mod toast;
pub mod viewing;

/// Every domain's steps.
pub fn register(steps: &mut Steps) {
    connection::register(steps);
    connection_health::register(steps);
    draft::register(steps);
    header::register(steps);
    mc::register(steps);
    navigation::register(steps);
    orchestration_view::register(steps);
    plan::register(steps);
    stash::register(steps);
    storage_layout::register(steps);
    stream::register(steps);
    thread_menu::register(steps);
    thread_snooze::register(steps);
    timeline::register(steps);
    toast::register(steps);
    viewing::register(steps);
}
