//! The step definitions, one file per desktop-qt steps file
//! (apps/desktop-qt/tests/native/features/<Name>Steps.cpp → `<name>.rs`),
//! each registering its steps and fake MC handlers in `register`.

use crate::harness::Steps;

pub mod add_project;
pub mod connection;
pub mod connection_health;
pub mod fake_files;
pub mod files_media;
pub mod files_workspace;
pub mod launch;
pub mod launch_folder;
pub mod machine_files;
pub mod mc;
pub mod other_machine;
pub mod project;
pub mod stream;
pub mod thread_menu;
pub mod thread_snooze;
pub mod timeline;
pub mod viewing;

/// Every domain's steps.
pub fn register(steps: &mut Steps) {
    add_project::register(steps);
    connection::register(steps);
    connection_health::register(steps);
    fake_files::register(steps);
    files_media::register(steps);
    launch::register(steps);
    launch_folder::register(steps);
    machine_files::register(steps);
    mc::register(steps);
    other_machine::register(steps);
    project::register(steps);
    stream::register(steps);
    thread_menu::register(steps);
    thread_snooze::register(steps);
    timeline::register(steps);
    viewing::register(steps);
}
