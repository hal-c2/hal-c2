//! The step definitions, one file per desktop-qt steps file
//! (apps/desktop-qt/tests/native/features/<Name>Steps.cpp → `<name>.rs`),
//! each registering its steps and fake MC handlers in `register`.

use crate::harness::Steps;

pub mod connection;
pub mod connection_health;
pub mod fake_files;
pub mod launch;
pub mod mc;
pub mod project;
pub mod stream;
pub mod thread_menu;
pub mod thread_snooze;
pub mod timeline;
pub mod viewing;

/// Every domain's steps.
pub fn register(steps: &mut Steps) {
    connection::register(steps);
    connection_health::register(steps);
    fake_files::register(steps);
    launch::register(steps);
    mc::register(steps);
    project::register(steps);
    stream::register(steps);
    thread_menu::register(steps);
    thread_snooze::register(steps);
    timeline::register(steps);
    viewing::register(steps);
}
