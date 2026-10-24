//! The step definitions, one file per desktop-qt steps file
//! (apps/desktop-qt/tests/native/features/<Name>Steps.cpp → `<name>.rs`),
//! each registering its steps and fake MC handlers in `register`.

use crate::harness::Steps;

pub mod cluster;
pub mod connection;
pub mod connection_health;
pub mod connections;
pub mod mc;
pub mod member;
pub mod plugin;
pub mod settings_connections;
pub mod stream;
pub mod thread_menu;
pub mod thread_snooze;
pub mod timeline;
pub mod viewing;

/// Every domain's steps.
pub fn register(steps: &mut Steps) {
    cluster::register(steps);
    connection::register(steps);
    connections::register(steps);
    connection_health::register(steps);
    mc::register(steps);
    member::register(steps);
    plugin::register(steps);
    settings_connections::register(steps);
    stream::register(steps);
    thread_menu::register(steps);
    thread_snooze::register(steps);
    timeline::register(steps);
    viewing::register(steps);
}
