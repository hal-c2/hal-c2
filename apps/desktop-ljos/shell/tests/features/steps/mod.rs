//! The step definitions, one file per desktop-qt steps file
//! (apps/desktop-qt/tests/native/features/<Name>Steps.cpp → `<name>.rs`),
//! each registering its steps and fake MC handlers in `register`.

use crate::harness::Steps;

pub mod agents;
pub mod centre;
pub mod connection;
pub mod connection_health;
pub mod licenses;
pub mod link;
pub mod mc;
pub mod pull_request;
pub mod pull_request_list;
pub mod stream;
pub mod thread_menu;
pub mod thread_pull_request_link;
pub mod thread_snooze;
pub mod timeline;
pub mod viewing;

/// Every domain's steps.
pub fn register(steps: &mut Steps) {
    agents::register(steps);
    centre::register(steps);
    connection::register(steps);
    connection_health::register(steps);
    licenses::register(steps);
    link::register(steps);
    mc::register(steps);
    pull_request::register(steps);
    pull_request_list::register(steps);
    stream::register(steps);
    thread_menu::register(steps);
    thread_pull_request_link::register(steps);
    thread_snooze::register(steps);
    timeline::register(steps);
    viewing::register(steps);
}
