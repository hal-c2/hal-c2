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
pub fn register(engine: &Engine, version: ljos_engine::Version) {
    use ljos_engine::{MetaRef, QmlType};
    for meta in [
        timeline_model::TimelineModel::static_meta(),
        agents::AgentsModel::static_meta(),
        diff::DiffModel::static_meta(),
        file_tree::FileTreeModel::static_meta(),
        previews::ThreadPreviews::static_meta(),
        pull_requests::ThreadPullRequests::static_meta(),
        pull_request_review::PullRequestReview::static_meta(),
        thread_diff::ThreadDiff::static_meta(),
    ] {
        engine.register_type(crate::MODULE, version, MetaRef::Static(meta));
    }
}

#[cfg(test)]
mod agents_tests;
#[cfg(test)]
mod timeline_prop;
#[cfg(test)]
mod timeline_tests;
