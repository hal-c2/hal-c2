//! The step definitions, one file per desktop-qt steps file
//! (apps/desktop-qt/tests/native/features/<Name>Steps.cpp → `<name>.rs`),
//! each registering its steps and fake MC handlers in `register`.

use crate::harness::Steps;

pub mod add_project;
pub mod agents;
pub mod centre;
pub mod composer_brick;
pub mod connection;
pub mod connection_health;
pub mod device;
pub mod fake_files;
pub mod file_search;
pub mod files_explorer;
pub mod files_media;
pub mod files_workspace;
pub mod keybinding;
pub mod keymap;
pub mod launch;
pub mod launch_folder;
pub mod licenses;
pub mod link;
pub mod machine_files;
pub mod markdown;
pub mod mc;
pub mod other_machine;
pub mod project;
pub mod pull_request;
pub mod pull_request_list;
pub mod settings;
pub mod settings_pages;
pub mod settings_rows;
pub mod stream;
pub mod thread_menu;
pub mod thread_pull_request_link;
pub mod thread_snooze;
pub mod timeline;
pub mod turn;
pub mod viewing;

/// Every domain's steps.
pub fn register(steps: &mut Steps) {
    add_project::register(steps);
    agents::register(steps);
    centre::register(steps);
    composer_brick::register(steps);
    connection::register(steps);
    connection_health::register(steps);
    device::register(steps);
    fake_files::register(steps);
    file_search::register(steps);
    files_explorer::register(steps);
    files_media::register(steps);
    keybinding::register(steps);
    keymap::register(steps);
    launch::register(steps);
    launch_folder::register(steps);
    licenses::register(steps);
    link::register(steps);
    machine_files::register(steps);
    markdown::register(steps);
    mc::register(steps);
    other_machine::register(steps);
    project::register(steps);
    pull_request::register(steps);
    pull_request_list::register(steps);
    settings::register(steps);
    settings_pages::register(steps);
    settings_rows::register(steps);
    stream::register(steps);
    thread_menu::register(steps);
    thread_pull_request_link::register(steps);
    thread_snooze::register(steps);
    timeline::register(steps);
    turn::register(steps);
    viewing::register(steps);
}
