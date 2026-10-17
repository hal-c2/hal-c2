//! A thread's content as the desktop shows it: desktop-qt's TimelineModel
//! (the conversation's rows), TimelineSummary, AgentsModel (the Agents
//! tab), ThreadPreviews (the browser tabs), DiffModel and ThreadDiff (the
//! diff panel), FileTreeModel (the files panel), ThreadPullRequests (the
//! Pull requests tab) and PullRequestReview (a review tab), in Rust.
//!
//! Each model is a pure core that takes MC frames and replies and records
//! its row changes, and a thin `QmlObject` over it that is the model QML
//! binds (`ItemModel`) and forwards those changes as Ljós's row signals.

pub mod agents;
pub mod cache;
pub mod diff;
pub mod file_tree;
pub mod previews;
pub mod pull_request_review;
pub mod pull_requests;
pub mod rows;
pub mod summary;
pub mod thread_diff;
pub mod time;
pub mod timeline;
pub mod timeline_model;

use ljos::prelude::Engine;

/// Registers the thread view's types in `HalC2.Shell`, so the bricks can
/// name them (and make the creatable ones, `TimelineModel {}`).
pub fn register(engine: &Engine) {
    engine.register_module(ljos::module!("HalC2.Shell" 1.0 => [
        timeline_model::TimelineModel,
        agents::AgentsModel,
        diff::DiffModel,
        file_tree::FileTreeModel,
        previews::ThreadPreviews,
        pull_requests::ThreadPullRequests,
        pull_request_review::PullRequestReview,
        thread_diff::ThreadDiff,
    ]));
}

#[cfg(test)]
mod agents_tests;
#[cfg(test)]
mod timeline_prop;
#[cfg(test)]
mod timeline_tests;
