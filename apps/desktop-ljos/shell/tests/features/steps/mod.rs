//! The step definitions, one file per desktop-qt steps file
//! (apps/desktop-qt/tests/native/features/<Name>Steps.cpp → `<name>.rs`),
//! each registering its steps and fake MC handlers in `register`.

use crate::harness::Steps;

pub mod connection;
pub mod connection_health;
pub mod mc;
pub mod settings;
pub mod settings_pages;
pub mod settings_rows;
pub mod stream;
pub mod thread_menu;
pub mod thread_snooze;
pub mod timeline;
pub mod viewing;

/// Every domain's steps.
pub fn register(steps: &mut Steps) {
    connection::register(steps);
    connection_health::register(steps);
    mc::register(steps);
    settings::register(steps);
    settings_pages::register(steps);
    settings_rows::register(steps);
    stream::register(steps);
    thread_menu::register(steps);
    thread_snooze::register(steps);
    timeline::register(steps);
    viewing::register(steps);
}
