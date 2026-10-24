//! The step definitions, one file per desktop-qt steps file
//! (apps/desktop-qt/tests/native/features/<Name>Steps.cpp → `<name>.rs`),
//! each registering its steps and fake MC handlers in `register`.

use crate::harness::Steps;

pub mod checkpoint_edit;
pub mod clone;
pub mod connection;
pub mod connection_health;
pub mod git;
pub mod mc;
pub mod source_control_settings;
pub mod stream;
pub mod thread_menu;
pub mod thread_snooze;
pub mod timeline;
pub mod viewing;
pub mod workspace;

/// Every domain's steps.
pub fn register(steps: &mut Steps) {
    checkpoint_edit::register(steps);
    clone::register(steps);
    connection::register(steps);
    connection_health::register(steps);
    git::register(steps);
    mc::register(steps);
    source_control_settings::register(steps);
    stream::register(steps);
    thread_menu::register(steps);
    thread_snooze::register(steps);
    timeline::register(steps);
    viewing::register(steps);
    workspace::register(steps);
}
