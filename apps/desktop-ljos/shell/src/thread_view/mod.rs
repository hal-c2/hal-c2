//! A thread's content as the desktop shows it: desktop-qt's TimelineModel
//! (the conversation's rows), TimelineSummary, ThreadPreviews (the browser
//! tabs), DiffModel and ThreadDiff (the diff panel) and FileTreeModel (the
//! files panel), in Rust.
//!
//! Each model is a pure core that takes MC frames and replies and records
//! its row changes, and a thin `QmlObject` over it that is the model QML
//! binds (`ItemModel`) and forwards those changes as Ljós's row signals.

pub mod cache;
pub mod summary;
pub mod time;
pub mod timeline;
pub mod timeline_model;

#[cfg(test)]
mod timeline_prop;
#[cfg(test)]
mod timeline_tests;
